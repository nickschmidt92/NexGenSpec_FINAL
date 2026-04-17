# NexGenSpec — App Store Optimization (ASO)

**Last updated:** 2026-04-17
**Status:** Ready to paste into App Store Connect when submitting for public review

---

## Strategy in one paragraph

Apple's App Store search ranks on matches across **Title + Subtitle + Keywords + In-App Purchase names** (description text does NOT affect ranking, despite what most blogs claim). Character budgets are tight. So: brand stays in the Title, the strongest differentiator + top search phrase goes in the Subtitle, and the hidden Keywords field gets pure bag-of-words keyword stuffing — no duplicates of words already in Title or Subtitle (Apple ranks them automatically; duplicating wastes precious characters).

The #1 commercial search phrase in this category is **"home inspection"**. Second is **"property inspection"**. Competitors (Spectora, HomeGauge, InspectIt) are well-established. Our wedge is **native iPad app + LiDAR scanning + calendar conflict detection** — none of which competitors surface prominently.

---

## Field-by-field (paste these into App Store Connect)

### App Name (30 char limit)
```
NexGenSpec
```
**10 chars — 20 to spare, but don't use them.** Clean brand. Apple algorithmic signal from exact-match brand queries is strong, and clutter here hurts.

### Subtitle (30 char limit)
```
Home Inspection Reports
```
**23 chars.** This is the line users read first. "Home Inspection Reports" is the single highest-intent commercial phrase — an inspector Googling/searching-App-Store while shopping for software will type exactly this. Also ranks for the partial "home inspection" and "inspection reports" queries.

### Keywords (100 char limit, comma-separated, NOT user-visible)
```
inspector,property,condo,house,report,PDF,photo,annotate,LiDAR,scan,scheduler,calendar,voice,iPad
```
**100 chars exactly.** Rules of this field:
- No spaces after commas (saves chars)
- No words that are already in Title ("NexGenSpec") or Subtitle ("home", "inspection", "reports")
- Singular nouns preferred — Apple auto-pluralizes
- Mix of high-volume ("property", "PDF") + differentiator ("LiDAR", "voice") + persona ("inspector") + form factor ("iPad") + action verbs ("annotate", "scan")

### Promotional Text (170 char limit — updateable WITHOUT review)
```
New: Calendar tab schedules inspections and flags conflicts. LiDAR scans produce floor-plan PDFs. Voice commands keep your hands free on the roof.
```
**146 chars.** Use this to spotlight the most recent feature launch. Updateable anytime without resubmitting for review — good place to pre-announce TestFlight cohort feedback or sale pricing later.

---

## Description (4,000 char limit)

Goes into the "Description" field. Pure conversion copy — does NOT affect ranking, so optimize for the human reader who tapped your listing.

```
NexGenSpec turns every home inspection into a polished, branded report — on one iPad, in the time it takes to walk the house.

Built for working inspectors:

• FULL INSPECTION TEMPLATE
  Pre-loaded sections cover roof, attic, crawl space, ventilation, exterior, foundation, plumbing, electrical, laundry, heating & cooling, water heater, and ancillary services. Duplicate and customize any section for your own template library.

• PHOTOS, ANNOTATIONS, AND VOICE NOTES
  Tap to snap. Draw circles and arrows directly on a photo. Dictate observations hands-free while you're on a ladder.

• LIDAR ROOM SCANNING
  iPad Pro's LiDAR sensor captures room geometry in seconds. NexGenSpec generates a floor plan PDF you can include in the final report — clients love it.

• CALENDAR & SCHEDULING (NEW)
  Schedule inspections in-app. The Calendar tab syncs with iOS Calendar and flags scheduling conflicts against your existing events — before you double-book. Tap any day to see what else is on your plate.

• PROFESSIONAL PDF REPORTS
  Exports a branded report with your company logo, inspector contact details, buyer's and listing agents, photos, and signatures. Email directly from the app.

• CLIENT & AGENT CONTACTS
  Capture buyer's agent, listing agent, and client info once — it flows through to the report, the calendar event, and the invoice.

• SIGNATURES & FINALIZATION
  Inspector and client sign on the iPad. Signed inspections lock automatically, with a full audit trail for legal compliance.

• ENCRYPTED BACKUPS
  Admins can create passphrase-encrypted backups of every inspection, ready to restore on a new iPad.

• PRIVACY-FIRST
  Your inspection data lives on your device. Calendar access is optional. No photos, notes, or reports leave your iPad unless you explicitly export them.

WHO IT'S FOR

Home inspectors, property managers, contractors documenting jobs, and real-estate professionals doing pre-listing walkthroughs.

REQUIREMENTS

• iPad running iPadOS 17 or later
• iPhone compatible (report creation is iPad-optimized but syncing in and viewing reports works on iPhone)
• LiDAR scanning requires iPad Pro with LiDAR sensor (iPad Pro 2020 and newer)

SUBSCRIPTION

Create up to 3 inspections free. NexGenSpec Pro unlocks unlimited inspections, LiDAR scanning, PDF export, voice commands, and encrypted backups. Monthly or annual billing via your Apple ID. Cancel anytime in Settings > Subscriptions.

TERMS

Privacy Policy: https://nexgenspec.com/privacy
Terms of Service: https://nexgenspec.com/terms
Support: contact@nexgenspec.com
```

**Character count: ~2,050.** Well under the 4,000 limit. If you want to push more keywords in, add a second paragraph near the end with region-specific terms ("Colorado home inspectors", "Denver property inspection", etc.) — but that's only worth it if you're localizing.

---

## What's Left Out (on purpose)

- **Star-rating comparisons** ("better than Spectora!") — Apple rejects any competitor name.
- **Pricing specifics** in the description body — Apple auto-renders the subscription price from IAP metadata. Hardcoding duplicates cause rejection.
- **Claims about accuracy or legal admissibility** — legal risk; a client could sue if the report fails in court and you claimed "legally admissible."
- **Fake urgency** ("limited time") — App Review rejects it.
- **Emoji in the name or subtitle** — Apple rejects.

---

## Localization

English (U.S.) is the launch locale. Do not localize at v1 launch — per-locale maintenance burden is not worth it until you have signal that a non-English market exists (e.g., Canadian or UK inspector reaches out). When the signal comes, the priority order is: en-GB (British English, different spelling and RE terms) → en-CA → es-MX → fr-CA.

---

## Reviews & ratings strategy (post-launch)

Once Pro IAPs are live and a subscriber completes their 5th inspection, trigger the in-app `SKStoreReviewController` prompt — but NOT before. Prompting early nets mostly 1-star "I haven't used it yet" ratings. The "5 inspections" bar is a proxy for "this user has paid AND succeeded with the app," which correlates with 4-5 star reviews.

DON'T:
- Incentivize reviews (ban under App Review guideline 5.6.1)
- Ask via email until you have an email list of opted-in Pro users
- Prompt more than once per major version per Apple guideline

---

## Competitor quick-reference

These are the names ranking ahead of us in App Store search for "home inspection" (as of 2026-04). Knowing them ≠ copying them — knowing them = understanding what NOT to say.

| Competitor | Their wedge | What to differentiate against |
|---|---|---|
| Spectora | Established brand, web + iOS | Native iPad-first UX, LiDAR, offline-first |
| HomeGauge | Enterprise, strong PDF output | Simpler setup, no IT required |
| InspectIt | Cheap monthly price | LiDAR + voice (they have neither) |
| Tap Inspect | Template library | Calendar conflict detection is unique |
| Horizon Inspection | Desktop heritage | Built for iPad from day one |

---

## Revision tracking

When you change any field in App Store Connect, also update this document + timestamp. Keeping ASO versioned is how you notice when a subtitle change tanks or boosts rank.
