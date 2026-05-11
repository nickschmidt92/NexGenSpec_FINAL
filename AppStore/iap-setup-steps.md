# In-App Purchase Setup Runbook (NexGenSpec)

Operator guide for configuring the two NexGenSpec auto-renewing subscriptions in App Store Connect before App Store submission.

- **App bundle:** `com.nexgenspec.app`
- **Apple Team ID:** `CPTLCQYSJJ`
- **Subscription group ID:** `nexgenspec_pro`
- **Pricing canon:** NickOS decision **D-0045** (2026-04-27)
- **Rank/group config canon:** NickOS decision **D-0083** (2026-05-03 — verified correct, do not "fix")
- **Source of truth for product IDs:** `NexGenSpec.storekit` in the Xcode project

> **Standing rule:** This doc and `NexGenSpec.storekit` must agree on product IDs, prices, and group ranks. If they ever disagree, the .storekit file wins (it is what the running app reads) and this doc gets updated. Do not create a third source of truth.

---

## 1. What this configures + why

NexGenSpec ships with two auto-renewing subscriptions, both inside a single subscription group (`nexgenspec_pro`):

| Product ID | Display | Price | Group rank | Notes |
|---|---|---|---|---|
| `com.nexgenspec.annual` | NexGenSpec Pro — Annual | **$449/yr** | **1** | Higher rank = upgrade tier |
| `com.nexgenspec.monthly1` | NexGenSpec Pro — Monthly | **$49/mo** | **2** | Lower rank = base tier |

Shared `subscriptionGroupID = nexgenspec_pro` is what makes them upgrade/downgrade siblings in iOS. The `groupNumber` ranks (1 vs 2) define the order Apple presents them and which is treated as the "upgrade." Per D-0083, **rank 1=annual, rank 2=monthly is correct and intentional** — this is the standard Apple pattern. If a future audit re-flags this as "wrong," point to D-0083 and close the alarm.

Trial enforcement is handled **outside StoreKit** by Apple DeviceCheck (Option A, per D-0091 and the DeviceCheck runbook at `docs/devicecheck-setup.md`). Each device gets 3 free inspections; StoreKit free-trial periods are **not** configured for these products.

---

## 2. Prerequisites

- App Store Connect access with **App Manager** or higher role on the NexGenSpec app
- App Store Connect Issuer ID already saved at `~/Documents/nickos-secrets/asc-issuer-id.txt` (verified 2026-05-10 as valid 36-char UUID; closes T-01219)
- Bank, tax, and contracts complete in Agreements/Tax/Banking (otherwise IAPs cannot be approved)
- NexGenSpec app already exists in App Store Connect with bundle `com.nexgenspec.app`

Verify before continuing:

1. Open https://appstoreconnect.apple.com → **My Apps** → **NexGenSpec** loads
2. **Agreements, Tax, and Banking** → all three rows green
3. Apple Small Business Program: if you have not enrolled yet, do that FIRST (T-01206). The 15% rate vs the 30% rate is a $5k+/yr difference even at modest revenue, and enrolling after-the-fact only takes effect on future revenue.

---

## 3. Create the subscription group (one-time)

1. ASC → **NexGenSpec** → **Subscriptions** (left sidebar).
2. **Create a Subscription Group** → **Reference Name:** `NexGenSpec Pro` → **Save**.
3. Add a **Group Display Name** (user-visible): `NexGenSpec Pro` (or whatever appears in the iOS Subscription Management sheet — keep it short).
4. The group's internal ID will be auto-generated, but the .storekit file references this group via the friendly `subscriptionGroupID = "nexgenspec_pro"`. The ASC-generated internal ID is what the **server** uses; the friendly name in .storekit is what the **app** uses. These do not need to match string-for-string — only the app needs to find products by their product IDs.

---

## 4. Create the Annual product (rank 1)

1. Inside the subscription group → **Create Subscription**.
2. **Reference Name:** `NexGenSpec Pro Annual`
3. **Product ID:** `com.nexgenspec.annual`  ← **must match exactly**, no typos, lowercase, no version suffix
4. **Subscription Duration:** `1 Year`
5. **Subscription Group:** the group you created in §3
6. **Subscription Price** → choose **USD $449.00** as the base. ASC will auto-calculate other-currency tiers; accept the defaults unless you want to manually pin a non-US price.
7. **Family Sharing:** disabled (Solo subscription — Family Sharing is for shared-household consumer apps, not professional tools).
8. **Localizations (English U.S.):**
   - **Display Name:** `NexGenSpec Pro — Annual`
   - **Description:** `Unlimited home inspections, branded PDF reports, LiDAR scanning, invoicing, and encrypted backups. Billed annually.`
9. **Review Information:**
   - **Screenshot:** upload one paywall screenshot showing this product (1280×1920 PNG, no transparency)
   - **Review Notes:** `Auto-renewing annual subscription. Unlocks unlimited inspection creation after the 3-free-inspection trial. Trial is enforced by Apple DeviceCheck (server-side), not StoreKit intro offers — no free-trial period is configured on this product.`
10. **Save**.

---

## 5. Create the Monthly product (rank 2)

Repeat §4 with these substitutions:

| Field | Value |
|---|---|
| Reference Name | `NexGenSpec Pro Monthly` |
| Product ID | `com.nexgenspec.monthly1` |
| Subscription Duration | `1 Month` |
| Subscription Price | **USD $49.00** |
| Display Name | `NexGenSpec Pro — Monthly` |
| Description | `Unlimited home inspections, branded PDF reports, LiDAR scanning, invoicing, and encrypted backups. Billed monthly.` |
| Review Notes | Same as §4 step 9 |

---

## 6. Set the Subscription Group ranks

This is the step audits keep mis-flagging — per **D-0083** the config below is **correct**, not a bug.

1. Subscription Group page → **Subscription Levels** section
2. **Annual must be at rank 1** (top). **Monthly must be at rank 2** (below annual).
3. If they are swapped: drag annual above monthly. Save.

Why this order: rank 1 is treated as the upgrade tier; rank 2 is the base. When a Monthly subscriber taps "Upgrade" in iOS Subscription Management, iOS offers them the rank-1 product (annual). If you flipped these, monthly→annual upgrades would appear as downgrades and Apple would prorate them differently. Don't flip.

---

## 7. Verify locally with StoreKit configuration testing

Before submitting to Apple, sanity-check the products load correctly in the running app.

1. Open `NexGenSpec.xcodeproj` in Xcode.
2. Scheme → **NexGenSpec** → **Edit Scheme** → **Run** → **Options** tab.
3. **StoreKit Configuration:** select `NexGenSpec.storekit` (it should already be selected — this is the local-only sandbox file).
4. Run on a simulator or real iPad. Trigger the paywall.
5. **Expected:** both products appear with **$49/mo** and **$449/yr** labels. If either is missing or the price is wrong: stop, fix the .storekit file (`NexGenSpec/NexGenSpec.storekit`), do NOT push ASC config that disagrees with the .storekit canon.

Note: this is the **local** verification (.storekit file → simulator). ASC sandbox testing on a real device with a sandbox Apple ID is a separate flow handled after submission — Apple's review team also tests in sandbox before approving.

---

## 8. Submit

1. App Store Connect → **NexGenSpec** → **App Store** tab → **iOS App** → **+ Version or Platform** if a 1.0 version row does not already exist.
2. In the version's **In-App Purchases** section: **+ Add IAP** → select **both** `com.nexgenspec.annual` and `com.nexgenspec.monthly1`.
3. Make sure each IAP shows **Ready to Submit** status (green or yellow dot; never red).
4. The IAPs submit with the binary. You **cannot** submit IAPs for review without submitting the binary that uses them (and vice versa). One bundle, one review.

---

## 9. Troubleshooting

**"This In-App Purchase is missing metadata"**
Almost always a missing screenshot or missing localization. Open the IAP, scroll to the bottom, fill in whatever has a red dot next to it.

**"Product not available" inside the app on a real device (not simulator)**
The IAP is not yet Ready to Submit, or the bank/tax/contracts aren't green, or the bundle the device installed doesn't match `com.nexgenspec.app`. Check all three in that order.

**Sandbox tester sees the wrong price**
Sandbox Apple IDs are locale-pinned. The sandbox tester's storefront locale must match the locale you set the price for. If you only set USD pricing and the sandbox tester is on a UK storefront, they may see auto-converted prices that don't match $49/$449 exactly. This is expected — Apple's currency conversion is independent of yours.

**App Review rejects with "subscription terms not clear"**
The paywall must show: (a) auto-renew notice, (b) cancellation instructions, (c) link to terms and privacy. NexGenSpec's `PaywallView.swift` already includes all three per D-0084 (links go to `nexgenspec.com/privacy.html` and `nexgenspec.com/terms.html`, not the bare routes). If a future paywall edit drops any of these, App Review will reject.

**Pricing mismatch between this doc, NexGenSpec.storekit, and ASC**
Single source of truth = `NexGenSpec.storekit`. Update everything else to match it. If you intentionally change pricing, log a new decision (D-XXXX) in NickOS superseding D-0045 and update all three places in one coordinated change.

---

## 10. Post-submission

After Apple approves the IAPs + binary:

1. **Monitor TestFlight purchase flow** for one full purchase + cancel cycle on a sandbox Apple ID. Confirm `subscriptions.isPro` flips correctly inside the app.
2. **Apple Small Business Program** (T-01206): if not enrolled yet, enroll immediately — Apple does not retroactively apply the 15% rate.
3. **Log the actual launch date** as a NickOS decision (D-XXXX) and update P-0003 (NexGenSpec project) progress.

---

**End of runbook.**

Related files:
- `NexGenSpec/NexGenSpec.storekit` — canonical product config (read first if anything contradicts)
- `docs/devicecheck-setup.md` — trial enforcement (DeviceCheck), runs orthogonally to StoreKit
- `AppStore/metadata.txt` — App Store listing copy, pricing reflected here for reviewer notes only
- `marketing/ASO.md` — App Store Optimization keywords (does NOT hardcode pricing — Apple auto-renders from IAP metadata)

Related NickOS records:
- **D-0045** — final pricing: $49/mo + $449/yr auto-renewing, single subscription group
- **D-0083** — subscription group rank config is correct
- **D-0091** — DeviceCheck Option A chosen for trial enforcement
- **T-01222** — this runbook closes that task once executed
- **T-01206** — Apple Small Business Program (do this in parallel or before)
