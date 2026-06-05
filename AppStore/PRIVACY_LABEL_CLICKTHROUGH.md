# App Privacy Nutrition Label — ASC Click-Through

This is the answer set for App Store Connect → App Privacy. Source of truth is
`NexGenSpec/PrivacyInfo.xcprivacy` and the App Store audit performed
2026-05-15. Numbers in (parens) are App Store Connect's section headings.

---

## (1) Does this app collect data?

**Yes.**

---

## (2) Pick all data types collected

For each type, ASC asks: linked to user / used for tracking / purposes.

### Contact Info → Email Address

- **Collected:** ✓
- **Linked to user identity:** ✓
- **Used to track user:** ✗
- **Purposes:** App Functionality, Account Management

> Justification: Firebase Auth uses email/password or Sign in with Apple.
> Email is the account key (Apple private-relay address if the user hides it).
> Quoted from `PrivacyInfo.xcprivacy`.

### User Content → Photos or Videos

- **Collected:** ✓
- **Linked to user identity:** ✓
- **Used to track user:** ✗
- **Purposes:** App Functionality

> Justification: Inspection photos stored locally, attached to inspection
> records. Includes drone/thermal imagery the user imports.

### User Content → Other User Content

- **Collected:** ✓
- **Linked to user identity:** ✓
- **Used to track user:** ✗
- **Purposes:** App Functionality

> Justification: Inspection notes, client name, property address,
> defect commentary, signatures.
>
> Note (applies to Photos/Videos + Other User Content above): this content is
> stored on-device only and is never transmitted to NexGenSpec servers. Under
> Apple's definition ("collect" = transmitted off device), these two arguably
> belong in "Not Collected"; they are disclosed here conservatively. Revisit if
> cloud sync or server-side report storage ever ships.

### Location → Precise Location

- **Collected:** ✓
- **Linked to user identity:** ✗ (unlinked)
- **Used to track user:** ✗
- **Purposes:** App Functionality

> **Declare PRECISE, not Coarse** — the ASC label must match the binary's
> `PrivacyInfo.xcprivacy:90-108`, which declares
> `NSPrivacyCollectedDataTypePreciseLocation`. The app makes two on-demand,
> one-shot location requests (never background): (a) property-address auto-fill
> requests a ~100 m fix (`LocationService.swift:25`,
> `kCLLocationAccuracyHundredMeters` — Precise in Apple's taxonomy) and
> reverse-geocodes it via Apple's `CLGeocoder` (`LocationService.swift:86`) — a
> **network request that sends the precise coordinate to Apple only**; the
> resulting address is stored as user content and the coordinate itself is not
> retained; and (b) the inspection weather stamp sends an **approximate (~1 km)
> coordinate** to Open-Meteo (open-meteo.com, a free no-account weather API) —
> `WeatherService.swift:85` uses `kCLLocationAccuracyKilometer` + 2-decimal
> rounding before transmission. So a precise coordinate does leave the device
> (to Apple, for geocoding) and a coarsened one goes to Open-Meteo; neither is
> retained as a raw coordinate. That precise path is exactly why the label must
> be Precise. (Earlier drafts said "Coarse" — wrong: they missed the
> HundredMeters address path and would have mismatched the binary manifest.)

### Diagnostics → Crash Data

- **Collected:** ✓
- **Linked to user identity:** ✗ (unlinked)
- **Used to track user:** ✗
- **Purposes:** App Functionality

> Justification: Firebase Crashlytics. No identifying user data attached
> to crash reports — anonymized device-level only.

---

## (3) Data NOT collected

Click "No" on every other category. Specifically NOT collected:

- ✗ Health & Fitness
- ✗ Financial Info (credit card, payment info — Apple handles via IAP)
- ✗ Contacts (the device's address book)
- ✗ User content → Customer Support (no in-app support chat collecting messages)
- ✗ User content → Gameplay Content
- ✗ User content → Other Audio Data — stays **No** because audio exists only inside on-device walkthrough videos that are never uploaded or collected. ⚠️ Do **NOT** write "no microphone use" anywhere: the microphone **is** used to record that video audio (declared via `NSMicrophoneUsageDescription`). The category is still "No" (not *collected*), but the mic *is* used — never assert otherwise on the label or in App Review notes (Guideline 5.1.1, B-0063).
- ✗ Browsing History
- ✗ Search History
- ✗ Identifiers → User ID *(Firebase Auth UID is account-key only, not used for tracking)*
- ✗ Identifiers → Device ID *(DeviceCheck token is per-device anti-abuse only, not linked to user identity)*
- ✗ Purchases (Apple handles)
- ✗ Usage Data → Product Interaction *(no analytics)*
- ✗ Usage Data → Advertising Data
- ✗ Diagnostics → Performance Data
- ✗ Diagnostics → Other Diagnostic Data
- ✗ Sensitive Info
- ✗ Surroundings
- ✗ Body Data
- ✗ Other Data

---

## (4) Tracking summary

**Does this app use data to track users across other companies' apps and
websites?**

**No.** This is critical. `PrivacyInfo.xcprivacy:136` declares
`NSPrivacyTracking = false`. The app links only `FirebaseAuth` and
`FirebaseCrashlytics` (verified in `project.pbxproj`) — NOT
`FirebaseAnalytics`. No IDFA, no Facebook SDK, no ad networks. If ASC
prompts about ATT, the answer is "No, this app does not track users."

---

## (5) Required-reason API declarations

These are already declared in `NexGenSpec/PrivacyInfo.xcprivacy` and don't
need separate ASC entry, but ASC may surface them as a confirmation:

- `UserDefaults` — Reason CA92.1 ("access info from the same app group or app")
- `File timestamp APIs` — Reason C617.1 ("display to user in the current app")
- `Disk space APIs` — Reason E174.1 ("display to user in the current app")
- `System boot time APIs` — Reason 35F9.1 ("measure time in the current app")

All four are valid and pre-filled in the manifest.

---

## Final ASC review screen — what to verify

Before clicking "Publish":

1. **Data Linked to User** section shows: Email, Photos/Videos, Other User Content.
2. **Data Not Linked to User** section shows: Precise Location, Crash Data.
3. **Data Used to Track You** section is **empty**.
4. The summary card at the top reads something like *"Data Linked to You · Data Not Linked to You"* with no third pill.

If you see a "Data Used to Track You" pill anywhere, stop and re-verify —
something flipped accidentally. The correct end state has zero tracking
disclosures.
