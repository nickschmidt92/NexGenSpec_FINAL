# NexGenSpec — Scheduling Integration (Calendly + Everyone Else)

**Status:** Planning doc. No code changes committed.
**Author:** Nick + Claude, 2026-04-20
**Target:** NexGenSpec v1.1 (Tier 1), v1.2 (Tier 2), v2 (Tier 3)

---

## 1. Why this doc exists

Nick's own business (D.I.A. Inspections) uses Calendly linked to Gmail. Clients book at diainspection.com; confirmed bookings land in Gmail Calendar; iOS Calendar syncs Gmail Calendar; NexGenSpec already reads iOS Calendar for conflict detection. The gap is **one tap to convert a booked calendar event into a NexGenSpec inspection** — right now the inspector retypes everything.

For NexGenSpec's *customers* (other inspectors the app is sold to), the same flow applies regardless of their booking tool. Calendly, Acuity Scheduling, Square Appointments, Cal.com, ICS invite emails, manual calendar entries from phone calls — they all share a common bridge: **iOS Calendar via EventKit**.

This doc picks the integration strategy, sketches the architecture, and sets the phased rollout so we don't over-engineer v1.

---

## 2. Principle: calendar-first, connector-later

The decision that shapes everything else: **don't build per-vendor integrations until we have signal that the calendar-first generic approach is insufficient**.

| | Calendar-first (Tier 1) | Per-vendor OAuth (Tier 2+) |
|---|---|---|
| Scope | Every scheduling tool on the planet | One tool at a time |
| Backend | None | Cloud Functions, webhook receivers |
| Maintenance | Very low | Per-tool when vendor APIs change |
| Data richness | Limited to what's in the calendar event | Structured data from vendor APIs |
| Time to build | ~1 week | 2–3 weeks per vendor |
| Tester risk | Known — we already read iOS Calendar | Each vendor has its own failure surface |

**Tier 1 is the keystone.** Tier 2/3 only get built if customers specifically ask for deeper integration after using Tier 1.

---

## 3. Tier 1: "Import from Calendar" — universal

### Product description

On the Dashboard, the `+` button becomes a menu instead of a direct action:

- **Start New Inspection** — existing flow (blank form)
- **Import from Calendar** — new (pick an upcoming event, pre-fill form)

Tapping "Import from Calendar" opens a sheet listing the inspector's upcoming calendar events for the next 14 days. Tapping a row opens the existing New Inspection form, pre-populated with whatever we can parse from the event. Inspector confirms/corrects, taps Create.

### Pre-fill extraction

For each field on the New Inspection form, attempt this mapping. Fall back to blank if nothing matches — never invent data.

| Form field | Event source | Notes |
|---|---|---|
| Client Name | Parse from `event.title` | Most common pattern: `"Home Inspection with Sarah Johnson"` → split on " with ", take the tail. Fallback: full title. |
| Property Address | `event.location` | 90%+ of bookings have this filled. If blank, fall back to a regex scan of the notes for street-address-shaped text. |
| Client Email | Regex scan of `event.notes` | `\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z\|a-z]{2,}\b` — grab the first match that isn't `@nexgenspec.com` or the inspector's own email. |
| Client Phone | Regex scan of `event.notes` | US-format regex `(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}` |
| Inspector Name | `InspectorProfile.inspectorName` | Already stored per-user, no event lookup. |
| Start Date & Time | `event.startDate` | Direct. |
| Duration | `event.endDate` − `event.startDate` | Direct, in minutes. Caps at 4h if the event is longer (probably a bad data artifact). |

**Design note:** this is deliberately "good enough" parsing. We don't try to be smart. Inspector confirms the form before creating, so any parse miss costs them ~5 seconds of correction, not a silent failure.

### Cross-reference on import

Before opening the pre-filled form, check if an existing inspection already references this event (via a new `sourceCalendarEventIdentifier` field — see §6). If yes, show a sheet: "This event is already linked to the '1247 Willow Creek' inspection. Open it?" to prevent duplicate draft creation when the inspector taps the same Calendly event twice.

### Reschedule handling

Once an inspection has `sourceCalendarEventIdentifier = X`, the app periodically (or on Calendar tab load) checks whether EKEvent X still exists and whether its `startDate` has shifted. If it has, surface a soft banner on the inspection: *"The calendar event was rescheduled to [new time]. Update inspection date?"* with buttons `Update` / `Ignore`. Lets Calendly reschedules flow through without the inspector having to remember to sync.

If EKEvent X no longer exists, the banner says *"The calendar event was removed externally. Keep the inspection as-is or delete it?"*.

### What Tier 1 explicitly does NOT do

- No automatic draft creation. The inspector chooses when to import.
- No vendor-specific UI or branding ("Import from Calendly" is NOT a separate button).
- No real-time sync. Import is a one-time snapshot; the reschedule banner is the only ongoing hook.
- No custom-question mapping (Calendly intake forms not accessible via iOS Calendar).

### Effort

~1 week of engineering. Zero new dependencies. Zero backend.

---

## 4. Tier 2: Calendly-direct OAuth — richer data

### When to build

Only after **at least 20% of active inspectors use "Import from Calendar" weekly** for 60 days post-v1.1 launch. Below that threshold, deeper integration is pointless.

### What it adds over Tier 1

Calendly's API exposes structured data that doesn't survive the calendar-event round-trip:

- **Invitee email + phone** — provided directly instead of regex-parsed from notes
- **Custom questions** — "Foundation type?", "Square footage?", "Year built?" — fields the inspector configured in their Calendly intake form
- **Event type** — maps to a template ("Pre-listing inspection" → use the condensed template; "Full buyer's inspection" → use the full template)
- **Cancellation** — Calendly fires a cancellation event when a client cancels; we can auto-archive the corresponding inspection

### Product shape

1. Settings → new section: "Scheduling Integrations"
2. Button: "Connect Calendly" → OAuth 2.0 flow
3. After connect:
   - Polling every 15 min via Cloud Function (or webhook if the inspector's Calendly tier supports it)
   - New confirmed bookings auto-create **draft inspections** (not just import candidates)
   - Confirmation notification: "New Calendly booking: Sarah Johnson · Tomorrow 2 PM"
4. Per-event-type template mapping UI: "Events of type X create inspections using template Y"
5. Optional: Calendly custom question → Inspection field mapping (advanced, maybe defer to Tier 2.5)

### Architecture

- **OAuth credentials**: store per-inspector encrypted in Firestore (new `/users/{uid}/integrations/calendly` doc)
- **Webhook receiver**: new Cloud Function `calendlyWebhook` that validates the Calendly signature, looks up the inspector by webhook target, creates the inspection in Firestore
- **Poll fallback**: scheduled Cloud Function every 15 min for inspectors whose Calendly tier doesn't support webhooks (Basic plan)
- **Refresh tokens**: Calendly's tokens expire in 2 hours; store refresh token + auto-refresh
- **Rate limits**: Calendly v2 API is 1000 req/hr; easy to stay under even at scale

### Effort

2–3 weeks. Needs Cloud Functions work + new Firestore schema + Settings UI + OAuth flow.

### Risk

Calendly API is v2 (stable) but Calendly has been owned by Dropbox-spinoff ownership and may sunset features. Bet only what we're willing to re-engineer if Calendly changes course.

---

## 5. Tier 3: Multi-vendor connector — enterprise

### When to build

Only after **two or more paying customers** specifically request integration with a non-Calendly tool. Don't anticipate.

### Scope

Abstract `BookingConnector` protocol with per-vendor implementations:

- **Calendly** (Tier 2 becomes the reference impl)
- **Acuity Scheduling** (OAuth, similar shape)
- **Square Appointments** (OAuth, part of Square's broader API)
- **Cal.com** (open-source Calendly alternative; gaining traction)
- **Generic ICS URL subscription** (paste a calendar feed URL, poll it — covers any tool that exposes ICS)

All connectors feed into the same "create draft inspection" path; the UI stays single-vendor-agnostic.

### Effort

2 weeks per vendor after the first (Calendly). Maybe 6–8 weeks total for all four.

---

## 6. Data model additions

Tier 1 adds **one** field to `Inspection`:

```swift
/// If this inspection was created by importing an iOS Calendar
/// event (via "Import from Calendar" or — in Tier 2 — via a
/// Calendly-origin webhook that wrote through EventKit), this is
/// the source event's EKEvent identifier.
///
/// Distinct from `calendarEventIdentifier`, which is the event
/// NexGenSpec CREATED for the inspection (when the inspector
/// tapped "Add to Calendar"). This one is the REVERSE direction:
/// the event that ORIGINATED the inspection.
///
/// Used for:
///   - Detecting reschedules (periodic check if startDate changed)
///   - Preventing duplicate imports (same event → same inspection)
///   - Future telemetry ("X% of inspections come from imported bookings")
public var sourceCalendarEventIdentifier: String?
```

Backward-compat: add to `CodingKeys`, `decodeIfPresent` with nil default, `encodeIfPresent` so older JSON files are unchanged.

Tier 2 adds Firestore schema (out of scope for v1 local-only data):

```
/users/{uid}/integrations/{provider}
  - accessToken (encrypted)
  - refreshToken (encrypted)
  - expiresAt
  - connectedAt
  - providerUserId
  - webhookId (if supported)
```

---

## 7. UI sketch

### Dashboard `+` menu

```
┌─────────────────────────────┐
│ + New Inspection            │  ← existing
├─────────────────────────────┤
│ 📅 Import from Calendar     │  ← new (Tier 1)
└─────────────────────────────┘
```

### Import sheet

```
┌───────────────────────────────────────────┐
│  Import from Calendar         Done   ✕   │
├───────────────────────────────────────────┤
│  NEXT 14 DAYS                             │
│                                           │
│  TOMORROW · Mon Apr 21                    │
│  ┌─────────────────────────────────────┐ │
│  │ 🗓 Home Inspection with Sarah Johnson │ │
│  │ 2:00 PM – 6:00 PM                    │ │
│  │ 📍 1247 Willow Creek Rd, Boulder, CO │ │
│  │ Source: Calendly (nickschmidt92@…)   │ │
│  └─────────────────────────────────────┘ │
│                                           │
│  TUE · Apr 22                             │
│  ┌─────────────────────────────────────┐ │
│  │ 🗓 Pre-listing Inspection            │ │
│  │ 10:00 AM – 12:00 PM                  │ │
│  │ 📍 42 Oak Street                     │ │
│  └─────────────────────────────────────┘ │
│                                           │
└───────────────────────────────────────────┘
```

Tap a row → pre-filled New Inspection sheet.

### Reschedule banner (inside a draft inspection)

```
┌────────────────────────────────────────────┐
│ 📅 Calendar event moved — it's now at     │
│    3:00 PM tomorrow instead of 2:00 PM.    │
│                                            │
│    [ Update ]   [ Ignore ]                 │
└────────────────────────────────────────────┘
```

Dismissed = stored in UserDefaults so it doesn't re-appear for the same event.

---

## 8. Rollout plan

### Phase 1 (v1.1): Tier 1 import — 1 week

- **Week 1**
  - Day 1–2: add `sourceCalendarEventIdentifier` model field + Codable + migration
  - Day 2–3: "Import from Calendar" sheet view
  - Day 3–4: Event-to-form parsing logic + fallbacks
  - Day 4: Duplicate detection via existing `sourceCalendarEventIdentifier` lookup
  - Day 5: Reschedule banner + refresh logic
  - Day 5: Integration tests + smoke test with real Calendly event on Nick's iPad

- **Week 2** (buffer)
  - TestFlight cohort feedback
  - Bug fixes

### Phase 2 (v1.2): Tier 2 Calendly OAuth — 2–3 weeks

Only if usage data from Phase 1 shows ≥20% weekly-active import.

### Phase 3 (v2): Tier 3 multi-vendor — when customer demand surfaces

Not before.

---

## 9. Open questions

1. **Duplicate detection threshold.** If an inspector taps the same Calendly event twice, we surface "open existing inspection" — but what if they WANT to create a second inspection for the same event (revision / re-inspection)? Leaning: offer "Open existing" as default, but also have a "Create another" button.

2. **Reschedule banner auto-apply?** Should the inspection's `inspectionDate` update automatically when the source event moves, or always require the "Update" tap? Leaning: require tap. Auto-update is magic in a scary way if the inspector already adjusted the time manually.

3. **Events from multiple calendars.** iPad may have iCloud + Gmail + company calendars all exposed. Show all by default or let inspector pick which calendars to import from? Leaning: all by default with a Settings toggle to filter.

4. **How to parse the inspector's own blocked-off time vs bookings?** Both live in the calendar. Leaning: don't filter — show everything, inspector picks. The cost of a wrong filter (hiding a real booking) is higher than the cost of clutter.

5. **Do we write the `calendarEventIdentifier` (NexGenSpec-authored event) back on the imported event's source?** I.e., do we link the two events bidirectionally? Leaning: no, keep them separate. The source event is the inspector's source of truth; NexGenSpec shouldn't modify events it doesn't own.

6. **What if the inspector doesn't have iOS Calendar permission yet?** The Import button would be disabled with a "Enable Calendar access in Settings" prompt. Same pattern as the Calendar tab's existing permission gating.

7. **Custom title patterns.** Should we let inspectors configure their own title parser? ("My titles look like: `{propertyAddress} - {clientName}`"). Probably v1.2+ feature, overkill for v1.1.

---

## 10. What we do NOT build (explicitly)

- Manual ICS file import (pick a `.ics` attachment from email). Complex file handling, rare use case, Tier 3 territory.
- Inspection-side calendar event editing (change title/location in NexGenSpec → update the source calendar event). Risky, inspector might lose the Calendly metadata.
- Two-way Calendly sync (rescheduling inside NexGenSpec propagates back to Calendly). Requires Calendly write-scope OAuth + is a common user footgun.
- Payment integration (Calendly can collect payments — we don't care, that's between the client and the inspector's own payment processor).

---

## 11. Personal dogfood path (Nick specifically)

Nick runs D.I.A. Inspections. His own Calendly → Gmail Calendar flow already works. On day-one of Tier 1 shipping:

1. iPad's iOS Calendar is signed into his Gmail → Calendly bookings appear there
2. Open NexGenSpec → Dashboard → `+` → Import from Calendar
3. His next DIA booking is in the list
4. Tap → pre-filled form → Create → inspection ready to go

If Tier 1 works for Nick dogfooding DIA, it'll work for every other inspector regardless of their booking tool.

---

## 12. Success metrics (post-v1.1)

Watch for 90 days after Tier 1 ships:

- **Import-usage rate**: % of created inspections that came from calendar import vs blank create. Target: ≥30%.
- **Duplicate-rate**: % of imports that hit the "already linked" dialog. High number = inspectors aren't tracking which events they've imported; may need better visual indicator.
- **Reschedule banner accept rate**: % of reschedule banners where user taps Update vs Ignore. Low number = banner is annoying, drop it.
- **Calendar permission-grant rate**: % of new users who grant Full Access. This feature requires it.

If import-usage is <10% after 60 days → Tier 1 was wrong call, revisit.
If it's ≥30% → Tier 2 Calendly OAuth becomes justified.

---

## 13. Parking lot

- **"NexGenSpec for Gmail"** Chrome extension that detects booking confirmation emails and one-click creates an inspection from the parsed email body. Completely bypasses calendar. Post-launch lever.
- **"Share to NexGenSpec"** iOS share-sheet extension that accepts any .ics file, pdf, or text and creates an inspection. Same idea as email parser but iOS-native. Also post-launch.
- **Inspector availability block**: inverse feature — NexGenSpec tells Calendly which days/times the inspector is unavailable (days with existing inspections, or travel blocks). Syncs via CalDAV. Interesting v2 feature if inspectors say they double-book.

---

**Next review of this doc:** When Tier 1 is scoped to a real branch, OR when customer feedback specifically mentions scheduling integration, whichever comes first. Do NOT start Tier 2 before Tier 1 ships + 60 days of usage data.
