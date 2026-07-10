# NexGenSpec — App Store Listing Copy (1.0.0, build 32 — canonical ASC source)

Final, verified listing fields for the App Store submission. Source of truth for copy.
Status + remaining ASC steps live in NickOS **T-01582**. Monetization model: `~/.claude/projects/-Users-nicholasschmidt/memory/nexgenspec-monetization-model.md`. Review notes: `AppStore/REVIEW_NOTES.md`.

## Subtitle (App Information, ≤30)
Home & Commercial Inspections

## Promotional Text (≤170 — pick ONE; default #1)
1. Inspect, scan, and deliver on site. Capture photos, mark up defects, generate a signed PDF report, and email it to your client before you leave.
2. LiDAR room scans, Apple Pencil photo markup, defect tagging, custom templates, signatures, invoicing, and finalized PDF reports in one app.
3. Start free: 3 full inspections, no card. LiDAR scanning and photo annotation are always free. Go Pro for unlimited watermark-free reports.

## Keywords (≤100, no spaces)
inspector,report,defect,checklist,punch,list,property,building,realty,LiDAR,floor,plan,scan,invoice

## Support URL
https://nexgenspec.com

## Copyright
2026 NexGenSpec

## Description (3,965 chars — VERIFIED; paste lines 24–54 ONLY, ending at the PLATFORM paragraph. ASC hard cap = 4,000. The Terms/Privacy URLs are NOT part of the Description — they go in ASC's own fields, see "## Store URLs" below.)
Professional inspection reports for home AND commercial property, built on iPhone, iPad, and Apple Silicon Mac. NexGenSpec lets residential and building inspectors capture a job, document every defect with photos, and hand the client a signed, polished PDF before leaving the site. One workflow for single-family homes, multi-unit buildings, and commercial assets.

Start from a built-in inspection template or build your own. Walk the property, snap photos, mark up findings, tag defects by severity, and finalize a tamper-evident report your clients and their agents can trust.

KEY FEATURES
- LiDAR room capture: scan a space in 3D and auto-generate a top-down floor plan plus a USDZ model. LiDAR scanning requires a compatible device.
- Photo annotation: draw freehand, add arrows and circles, pick red/yellow/green, with full undo/redo. Works with Apple Pencil on iPad and with your finger too. Marks stay editable and never overwrite the original photo.
- AI defect detection: on-device photo analysis suggests defect tags as you work; accepted tags carry through to the report.
- Structured findings: rate each item's status (Inspected / Not Inspected / Not Present) and severity, write up Location, Observed, Implication, Recommendation, and comments, add a contractor referral tag, or omit any item from the client report.
- Add custom items to any section on the fly, beyond your template.
- Attach it all: in-app photos and walk-through video, plus drone and thermal imagery you import (added from your photo library, e.g. AirDropped media), organized right on the inspection.
- Reminders and to-dos: set per-inspection reminders with optional due dates and checkable task lists so nothing gets missed on site.
- Custom templates: duplicate the built-in template or create your own sections and items, reorder, and reuse across jobs.
- Severity-rated reports: cover page, a dedicated severity-sorted defect summary table with safety/major/marginal/minor badges, and per-item photo cards with annotations baked in.
- Your branding: import your company logo and add name, license number, and contact details to auto-fill every report and replace the NexGenSpec logo on PDFs.
- Real estate agents: capture buyer's and listing agent details for the report and CC them when you send.
- Tamper-evident: each finalized report carries a unique Report ID and SHA-256 integrity hash.
- Locked signatures: capture inspector and client signatures on a signature pad, each stamped with a timestamp and device ID, for a defensible record.
- Inspection timer: time on site is tracked automatically, pausing when you switch away and resuming when you return.
- Auto-save with an on-screen saved indicator; manual save.
- Invoicing: build a price/services/total invoice, email the report and invoice to your client, CC agents, and track sent/paid status.
- Export anywhere: paginated US-Letter PDF, a Pro plain-text quick summary, or a full ZIP backup (report, photos, actual video files, manifest, integrity file). Reports auto-file by property address and a built-in browser lets you re-share past PDFs and backups.
- Scheduling: add inspections to your device calendar with reminders, view an in-app month calendar, and see conflicts with your other events.
- Weather and total inspection time logged automatically; current-location address auto-fill.
- Sign in with Apple or email, with a recovery email, secure account management, and account deletion with a receipt.

START FREE
Run 3 full inspections free with watermarked reports. Upgrade to Pro for unlimited inspections and clean, watermark-free reports. No credit card required to start.

PLATFORM
Universal app for iPhone and iPad, and runs on Apple Silicon Mac. Apple Pencil supported for annotation on iPad. LiDAR scanning requires a compatible device. Photo and video capture need a device camera (on Mac, import from your photo library); current-location address auto-fill is available on iPhone and iPad.

<!-- ↑ Description ENDS here (3,965 chars). Do NOT paste anything below into the ASC Description field. -->

## Store URLs (paste into ASC's DEDICATED fields, NOT the Description)
- **Privacy Policy URL** (ASC App Privacy page): https://nexgenspec.com/privacy.html
- **EULA / Terms of Use** (ASC App Information → License Agreement, or leave Apple's standard EULA and link in Support): https://nexgenspec.com/terms.html
- **Support URL**: https://nexgenspec.com
- Use `.html` URLs — the bare `/privacy` and `/terms` routes 404.

## App Privacy (collect = YES; Tracking = NO)
- Contact Info > Email Address — Linked, App Functionality
- Location > Precise Location — NOT Linked, App Functionality  (CLGeocoder ~100m address auto-fill SHIPS; weather ~1km to Open-Meteo. Confirmed precise — do NOT downgrade to Coarse.)
- User Content > Photos or Videos — Linked, App Functionality
- User Content > Other User Content — Linked, App Functionality
- Diagnostics > Crash Data — NOT Linked, App Functionality
- NOTE: location is shared with Open-Meteo (THIRD PARTY) for weather — answer the third-party-sharing questions accordingly.
- iCLOUD SYNC (default ON): inspections — the inspection record, report PDF, thumbnails, and LiDAR floor plans — sync across the user's OWN Apple devices through their PRIVATE iCloud account (Apple CloudKit private DB). This is the user's own iCloud, NOT a NexGenSpec server and NOT a data-broker third party — NexGenSpec never receives, stores, or can access the data. User Content here (Photos/Videos + Other User Content) is therefore Linked to the user, but is the user's own data routed through their own iCloud. Users can turn on Local-Only mode to keep inspections on one device. Sync is one user across their own devices only — there is NO multi-user/company-team sharing. See `AppStore/SYNC_DISCLOSURE_DRAFT.md` for the App Privacy mapping and the open attorney/Apple-policy question on whether the user's own private iCloud counts as third-party sharing for the label.
- Privacy Policy URL (entered on the App Privacy page): https://nexgenspec.com/privacy.html

## ⚠️ Marketing rewrite pending
Nick is sourcing a marketing-expert rewrite of the Description (prompt issued 2026-06-23). If new copy comes back: length-check (≤4000) AND accuracy-check against the verified feature set above before pasting. Accuracy guardrails: do NOT claim data is local-only / on-device-only / "never leaves your device" (FALSE under default-ON iCloud sync); if sync is mentioned, frame it correctly (inspections sync across the user's OWN devices via their PRIVATE iCloud / CloudKit, NexGenSpec never stores them, sync is NOT a backup, deletions propagate, no multi-user/team sharing); drone/thermal are IMPORT not capture; no prices.
