# NexGenSpec — App Store Listing Copy (1.0.0, build 36 — canonical ASC source)

Final, verified listing fields — ENTERED INTO ASC 2026-07-10..12 (this file mirrors what is live in the ASC form).
Passed a 6-lens adversarial audit 2026-07-10. Review notes: `AppStore/REVIEW_NOTES.md`.

## Name (≤30)
NexGenSpec

## Subtitle (App Information, ≤30)
Home & Commercial Inspections

## Keywords (98/100, no spaces)
inspector,report,defect,checklist,punch,list,property,realtor,walkthrough,contractor,invoice,LiDAR

## Promotional Text (165/170)
Scan a room with LiDAR to auto-generate a floor plan. Mark up defects, capture e-signatures, and deliver a tamper-evident PDF — all on your device, before you leave.

## Support URL
https://nexgenspec.com

## Marketing URL
https://nexgenspec.com

## Copyright
2026 NexGenSpec

## Description (3,963/4,000 — paste ONLY the block between the markers)
<!-- ↓ Description STARTS -->
Professional inspection reports for home AND commercial property, built on iPhone, iPad, and Apple Silicon Mac. NexGenSpec lets residential and building inspectors capture a job, document every defect with photos, and hand the client a signed, polished PDF before leaving the site. One workflow for single-family homes, multi-unit buildings, and commercial assets.

Start from a built-in inspection template or build your own. Walk the property, snap photos, mark up findings, tag defects by severity, and finalize a tamper-evident report your clients and their agents can trust.

KEY FEATURES
- LiDAR room capture: scan a space in 3D and auto-generate a top-down floor plan plus a USDZ model. LiDAR scanning requires a compatible device.
- Photo annotation: draw freehand, add arrows and circles, pick red/yellow/green, with full undo/redo. Works with Apple Pencil on iPad and with your finger too. Marks stay editable and never overwrite the original photo.
- Structured findings: rate each item's status (Inspected / Not Inspected / Not Present) and severity, write up Location, Observed, Implication, Recommendation, and comments, add a contractor referral tag, or omit any item from the client report.
- Add custom items to any section on the fly, beyond your template.
- Attach it all: in-app photos and walk-through video, plus drone and thermal imagery you import from your photo library, organized right on the inspection.
- Reminders and to-dos: set per-inspection reminders with optional due dates and checkable task lists so nothing gets missed on site.
- Custom templates: duplicate the built-in template or create your own sections and items, reorder, and reuse across jobs.
- Severity-rated reports: cover page, a dedicated severity-sorted defect summary table with safety/major/marginal/minor badges, and per-item photo cards with annotations baked in.
- Your branding: import your company logo and add name, license number, and contact details to auto-fill every report and replace the NexGenSpec logo on PDFs.
- Real estate agents: capture buyer's and listing agent details for the report and CC them when you send.
- Private by design: your inspections stay on your device and sync only through your own iCloud — never our servers. Works fully offline, with a Local-Only mode.
- Tamper-evident: each finalized report is sealed with a unique Report ID and SHA-256 integrity hash, so any change to the sealed data is flagged.
- Locked signatures: capture inspector and client signatures on a signature pad, each stamped with a timestamp and device ID, for a defensible record.
- Inspection timer: time on site is tracked automatically, pausing when you switch away and resuming when you return.
- Invoicing: build a price/services/total invoice, email the report and invoice to your client, CC agents, and track sent/paid status.
- Export anywhere: paginated US-Letter PDF, a Pro plain-text quick summary, or a full ZIP backup (report, photos, actual video files, manifest, integrity file). Reports auto-file by property address and a built-in browser lets you re-share past PDFs and backups.
- Scheduling: add inspections to your device calendar with reminders, view an in-app month calendar, and see conflicts with your other events.
- Weather logged automatically; current-location address auto-fill.
- Sign in with Apple or email, with a recovery email, secure account management, and account deletion with a receipt.

START FREE
Run 3 full inspections free with watermarked reports. Upgrade to Pro for unlimited inspections and clean, watermark-free reports. No credit card required to start.

PLATFORM
Universal app for iPhone and iPad, and runs on Apple Silicon Mac. Apple Pencil supported for annotation on iPad. LiDAR scanning requires a compatible device. Photo and video capture need a device camera (on Mac, import from your photo library). In-app email with agent CC works on iPhone and iPad; on Mac, delivery is via the share sheet.
<!-- ↑ Description ENDS (3,963 chars). Do NOT paste anything below into the ASC Description field. -->

## Store URLs (paste into ASC's DEDICATED fields, NOT the Description)
- **Privacy Policy URL** (ASC App Privacy page): https://nexgenspec.com/privacy.html
- **EULA**: Apple's Standard EULA (selected in App Information); site terms at https://nexgenspec.com/terms.html
- Use `.html` URLs — the bare `/privacy` and `/terms` routes 404.

## App Privacy — AS PUBLISHED in ASC 2026-07-10 (3 data types, Tracking = NO)
- Contact Info > Email Address — Linked to identity, App Functionality
- Location > **Coarse Location** — NOT Linked, App Functionality
- Diagnostics > Crash Data — NOT Linked, App Functionality

This CORRECTED an earlier over-declaration (5 types incl. Precise Location and
User Content). Rationale: inspection content (photos/reports/scans) is NOT
"collected" under Apple's definition — it lives on-device and syncs only
through the user's PRIVATE iCloud (CloudKit private DB); NexGenSpec has no
server and never receives it. Location: the only location data retained is the
~1 km-coarsened weather coordinate (Open-Meteo); the precise CLGeocoder
coordinate for address auto-fill is transient and goes to Apple only.
Do NOT resurrect the old 5-type table (it lingers in ASC-PASTE-SHEET-build32.md — stale).

## In-App Purchases (ASC metadata — final copy)
- `com.nexgenspec.annualv1` · 1 Year · USD $449 · Display name: **NexGenSpec Pro — Annual**
- `com.nexgenspec.monthlyv1` · 1 Month · USD $49 · Display name: **NexGenSpec Pro — Monthly**
- Description (both, s/annually/monthly/): "Unlimited inspections and watermark-free, branded PDF reports with your company logo, across iPhone, iPad, and Mac. Billed annually."
- Pro = unlimited inspections + watermark-free reports ONLY (LiDAR, annotation, invoicing, backups are free-tier — do NOT list them as Pro).
