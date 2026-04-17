# NexGenSpec v2 — Team Features Planning Document

**Status:** Planning only. No code changes committed. Do not start implementation until TestFlight → public launch cycle has produced ≥3 paying customers asking for team features.

**Author:** Nick + Claude, 2026-04-17
**Target:** NexGenSpec v2.0.0 (a version bump, not a dot release — breaks data model)

---

## 1. Why this doc exists

We're about to ship v1 as a **solo-inspector** app. Team features are a likely v2 expansion, but they are also a fundamental rearchitecture — not a feature flag. This doc exists so that:

1. When we DO start building team features, architecture decisions are already made, not improvised under deadline pressure.
2. v1 decisions we make now (schema, pricing, onboarding) don't paint us into a corner for v2.
3. When a customer asks "do you support teams?", we have a grounded answer on scope + ETA.

---

## 2. Product shape — what "team" actually means

Home-inspection companies come in three shapes. We design v2 for **all three on the same schema**, gated by feature flags and pricing tier.

### Solo (= v1 today)
- One inspector, one iPad
- Owns their own templates, brand, inspections
- No one else can see their data
- This is 80%+ of U.S. home inspectors (per IBISWorld 2025 data)

### Small firm (target for v2 launch)
- 2–10 inspectors sharing a brand
- One owner (usually the founder), N admins, inspectors
- Shared templates, shared company logo, shared agent address book
- Individual inspectors do their own inspections on their own iPads; reports roll up to the firm
- This is ~15% of the market but ~40% of revenue potential (higher willingness to pay per seat)

### Enterprise (v3+, out of scope for v2)
- 50+ inspectors, regional managers
- SSO (SAML/OIDC), SCIM provisioning, custom branding, API access, white-label
- Out of scope — revisit after 10+ paying small-firm customers

---

## 3. Data model rearchitecture

**Current state:** All inspection data is local JSON files on one iPad, keyed by UUID. `InspectionStore` reads/writes `~/Documents/Inspections/`. Firebase Auth is used only for login — no user data is in Firestore.

**Target state:** Inspection data lives in Firestore, team-scoped. Local iPad is a cache, not the source of truth.

### Proposed Firestore schema

```
/teams/{teamId}
  - ownerId: uid
  - name: "ACME Home Inspections"
  - companyLogo: Storage URL
  - brand: { primaryColor, fontFamily, ... }
  - createdAt, subscriptionTier, seatCount, seatsUsed

/teams/{teamId}/members/{uid}
  - role: "owner" | "admin" | "inspector" | "viewer"
  - joinedAt
  - displayName, email (denormalized for UI)
  - licenseNumber, phone (inspector profile)

/teams/{teamId}/inspections/{inspectionId}
  - ...existing Inspection fields...
  - ownerUid: uid (which inspector created it)
  - assignedUids: [uid] (who can edit)
  - finalizedAt, status

/teams/{teamId}/templates/{templateId}
  - shared across whole team

/teams/{teamId}/agents/{agentId}
  - shared real-estate agent address book

/teams/{teamId}/invites/{inviteId}
  - invitedEmail, role, expiresAt, status
  - accessible via magic link + 6-digit code

/users/{uid}/teamMemberships: [teamId]
  - lets a user be in multiple teams
  - also lets us find "which teams does this user belong to" on login
```

### Key schema decisions + rationale

- **`/teams/{teamId}/inspections` not `/inspections/{id}` with teamId field** — simpler security rules, better Firestore query performance, natural cascade-delete on team removal.
- **`assignedUids` array, not single ownerUid** — lets two inspectors co-work an inspection (think: inspector + trainee).
- **`/users/{uid}/teamMemberships` denormalized list** — so we can check "which teams is this user in" with one read at login, rather than a collection-group query.
- **Templates + agents team-scoped from day one** — even solo users in v2 are in a "team of 1," and when they invite their 2nd user, the templates/agents they've built up come with them. No migration.

---

## 4. Role + permission matrix

| Action | Owner | Admin | Inspector | Viewer |
|---|---|---|---|---|
| Create team | ✅ (on signup) | — | — | — |
| Delete team | ✅ | — | — | — |
| Invite members | ✅ | ✅ | — | — |
| Change member roles | ✅ | ✅ (not Owner) | — | — |
| Remove members | ✅ | ✅ (not Owner) | — | — |
| Manage billing + seats | ✅ | — | — | — |
| Create/edit templates | ✅ | ✅ | — | ❌ |
| Manage company brand/logo | ✅ | ✅ | — | — |
| Create inspections | ✅ | ✅ | ✅ | — |
| Edit own inspections | ✅ | ✅ | ✅ | — |
| Edit others' inspections | ✅ | ✅ | — | — |
| Delete inspections (draft) | ✅ | ✅ | ✅ (own only) | — |
| Finalize inspections | ✅ | ✅ | ✅ | — |
| Export/email PDF to client | ✅ | ✅ | ✅ | — |
| View all team inspections | ✅ | ✅ | ✅ | ✅ |
| Admin Backup + Retention | ✅ | ✅ | — | — |
| Force test crash (debug only) | — | — | — | — |

**Viewer role exists** because some firms want to give a bookkeeper / office manager read-only access for billing / QA without them being able to modify inspections.

---

## 5. Security rules (Firestore)

Pseudocode for the key rules — actual rules live in `firebase/firestore.rules` when we build this:

```
// A user can read anything in a team they belong to
match /teams/{teamId}/{document=**} {
  allow read: if teamContains(teamId, request.auth.uid);
}

// But write access is role-gated
match /teams/{teamId}/inspections/{inspectionId} {
  allow create: if hasRole(teamId, ['owner', 'admin', 'inspector']);
  allow update: if hasRole(teamId, ['owner', 'admin']) ||
                   (hasRole(teamId, ['inspector']) && resource.data.ownerUid == request.auth.uid);
  allow delete: if resource.data.status == 'draft' && (
    hasRole(teamId, ['owner', 'admin']) ||
    resource.data.ownerUid == request.auth.uid
  );
}

function hasRole(teamId, allowedRoles) {
  let member = get(/databases/$(database)/documents/teams/$(teamId)/members/$(request.auth.uid));
  return member.data.role in allowedRoles;
}
```

**Rule of thumb:** every write rule reads the member doc. That's 1 extra read per write. Acceptable overhead; Firestore caches reads within a request.

---

## 6. Billing model

### Pricing hypothesis

| Tier | Price | What's unlocked |
|---|---|---|
| Free | $0 | 3 lifetime inspections, no team |
| Pro (solo) | $28.99/mo or $289.99/yr | Unlimited inspections, solo only |
| Team Starter | $59.99/mo or $599.99/yr | Up to 3 seats, all features |
| Team Growth | $19.99/mo per seat (flat) | 4–25 seats, all features |

**Why three tiers not two:** $59.99 flat for "up to 3" is a psychology anchor. Small firms see "up to 3" and think "I can have my wife do the scheduling" — they convert at the higher flat rate instead of doing the math on per-seat. At 4+ seats the per-seat math wins.

**Owner pays:** the team owner's Apple ID is billed. Seats are assignable via the admin dashboard.

**Seat overage behavior:** if a firm tries to invite a 4th seat while on Team Starter, the invite UI says "upgrade to Team Growth or remove a member" — NO silent overage billing (Apple won't allow this in IAP anyway, but it also creates user trust problems).

### App Store IAP vs Stripe

Apple requires IAP for any digital service consumed inside the app. So subscription must be IAP.

**Exception:** if we build a web app for team admins to manage billing (which is reasonable for firms), Apple's 2024 External Payment Entitlement lets us route team-tier billing through Stripe with a 27% Apple fee instead of 30%. Only worth doing if the web app is shipping anyway.

**Recommendation:** all subscriptions via IAP for v2.0. External-payment consideration deferred to v2.1.

---

## 7. UI changes

### New screens

1. **Create-or-Join choice** on first-time signup
   - "Create a new company" → creates a team-of-1 with user as owner
   - "Join a company" → takes invite code
2. **Invite flow** in Settings (owner/admin only)
   - Email input + role picker
   - Generates 6-digit code + magic link both
3. **Members list** in Settings
   - One row per member, role badge, "remove" button (owner/admin only)
4. **Team branding** in Settings
   - Company logo (already exists per-user — migrate to team-scoped)
   - Company name, website, primary color
5. **Admin dashboard tab** (new tab for owner/admin)
   - Shows all team inspections
   - Filter by inspector, status, date range
   - Export team metrics (inspections/week, finalize rate)

### Existing screens that change

- **Workspace tab:** now defaults to "My Inspections" but has a segmented control to switch to "All Team Inspections" (admin view)
- **Calendar tab:** each inspection shows which inspector owns it (small avatar/initials on the day cell)
- **Settings:** "Account" section splits into "My Account" + "Team" (owner/admin see both)
- **Inspector Profile:** license #, phone, email become per-user not per-team; company info becomes per-team
- **Inspection detail:** shows assigned inspector name near top; owner/admin see "Reassign" button

### Existing screens that stay the same

- **Inspection item detail** (section items, photos, annotations) — unchanged
- **PDF report output** — unchanged except branding comes from team not user
- **Finalize + signature flow** — unchanged

---

## 8. Onboarding flow changes

### v1 (current)
```
Splash → Sign In (Apple / email) → Dashboard (empty, "Create First Inspection")
```

### v2 proposed
```
Splash → Sign In
       ↓
       Is user a member of any team? (check /users/{uid}/teamMemberships)
       ↓                                    ↓
       YES: pick team                       NO: show create-or-join choice
           ↓                                    ↓
           Dashboard                           Create new company  OR  Enter invite code
                                                   ↓                      ↓
                                                   Team created,          Join team, role from invite
                                                   user = owner           ↓
                                                                          Dashboard
```

Fallback: user can be in multiple teams. Team switcher in top-left of Dashboard (like Slack workspace switcher).

---

## 9. Data migration (v1 → v2)

Every v1 user needs to become a v2 team owner without losing data. The migration happens on first v2 launch:

```
On v2 launch:
1. Check: is this user already in a team? (via /users/{uid}/teamMemberships)
2. If YES → skip migration, go to team picker
3. If NO → assume they're a v1 user with local data
   a. Create a new team: name = "<FirstName>'s Inspections"
   b. Add this user as owner
   c. Walk local ~/Documents/Inspections/ JSON files
   d. Upload each to /teams/{teamId}/inspections/
   e. Upload each inspection's photos to Cloud Storage
   f. Keep local files as backup, mark as "migrated"
   g. On successful upload, delete local copies (optional; can keep for offline cache)
4. User lands on Dashboard with all their data intact
```

**Gotchas:**
- Photos can be GB-scale. Migration needs progress UI + retry logic.
- Firestore cost spike during migration window — budget this in the Blaze plan.
- Older iPads on cellular-only: give user option to defer migration until on Wi-Fi.

---

## 10. Offline behavior

V1 works fully offline (local JSON). V2 needs to preserve this — an inspector in a basement with no signal must still be able to inspect.

**Firestore offline persistence** handles most of this. Strategy:
- Enable Firestore offline persistence (one line: `Firestore.setLoggingEnabled(true); settings.isPersistenceEnabled = true;`)
- Photos stored locally first, uploaded to Storage in background
- Conflict resolution: last-write-wins at field level. For photos, client-side UUID prevents collision.

**Edge case:** two inspectors on different iPads edit the same inspection offline. On reconnect, last-write wins. Not perfect; for v2 launch this is acceptable because assignment defaults to single-owner. Revisit for v2.1 with CRDT-based collab if customer asks.

---

## 11. Cloud Functions needed

| Function | Trigger | Purpose |
|---|---|---|
| `sendTeamInvite` | HTTPS callable | Generate invite code, send email via Resend |
| `acceptTeamInvite` | HTTPS callable | Validate code, add user to team members |
| `setCustomClaims` | Firestore trigger on members | Mirror role to Firebase Auth custom claims |
| `enforceSeatLimit` | Firestore trigger on member create | Block adds beyond tier's seat cap |
| `cascadeDeleteTeam` | Firestore trigger on team delete | Clean up subcollections + Storage |
| `dailyTeamDigest` | Schedule 07:00 local | Owner gets daily "yesterday's inspections" email |

---

## 12. Open questions (decide before coding)

1. **Solo users on Pro subscription — do they migrate to the "team of 1" model automatically in v2, or stay on solo-only forever?**
   - Leaning YES migrate → simpler code path, easier upsell to team later
2. **Can an inspector be in multiple teams simultaneously?**
   - Leaning YES → contractors who freelance for multiple firms
3. **Who owns the inspection data if the team is deleted?**
   - Leaning: export-before-delete required, 30-day soft-delete window
4. **Does the Calendar tab show everyone's inspections or just mine?**
   - Leaning: default to mine, toggle to team
5. **Should viewers be able to see photos, or just aggregate report data?**
   - Leaning: see everything read-only (bookkeeper use case needs to verify completeness)
6. **Do we support existing v1 iPad keeping local-only mode, or force everyone to cloud in v2?**
   - Leaning: force cloud → simpler product surface, cloud-sync is the main v2 value

---

## 13. Rollout plan (when this becomes active work)

### Phase 1 — Foundation (3–4 weeks)
- Firestore schema + security rules
- Migration path
- Offline persistence
- Cloud Functions for invite/accept
- No UI changes yet — existing app reads/writes Firestore but still single-user

### Phase 2 — UI changes (2–3 weeks)
- Create-or-Join onboarding
- Invite + Members UI
- Admin dashboard tab
- Role badges in inspection list

### Phase 3 — Billing (1–2 weeks)
- New IAP products in ASC
- Team tier gating
- Seat-limit enforcement
- Upgrade/downgrade flow

### Phase 4 — Beta (2 weeks)
- TestFlight external cohort of 3–5 small firms
- Dog-food with beta testers
- Address feedback

### Phase 5 — Launch (1 week)
- Submit v2 to App Store
- Release marketing: blog post, email to existing users
- Monitor churn of solo users (should be low — they get cloud sync as a bonus)

**Total: ~10–12 weeks of focused work.** Real-calendar time likely 3–4 months accounting for review + polish.

---

## 14. Success metrics (post-launch)

Watch these for 90 days after v2 ships:

- **Team creation rate:** % of new signups that pick "Create team" vs "Join team" vs decline
- **Team tier conversion rate:** % of Pro subscribers who upgrade to Team within 90 days
- **Invite acceptance rate:** % of sent invites that become active members
- **Solo-to-team churn risk:** do existing Pro subscribers cancel because v2 feels "too much"? Target <2%.
- **Support ticket volume:** team-related tickets should be <15% of all tickets

If team tier conversion is <3% after 90 days, reconsider pricing. If solo churn spikes, build a "stay solo" preference in Settings.

---

## 15. What we do NOT build in v2

To keep scope finite:

- **SSO / SAML** — enterprise only, v3
- **API for third-party integrations** — power users can wait
- **White-label / custom domain reports** — enterprise v3
- **Cross-team sharing** (one inspection visible to multiple teams) — edge case, unclear real demand
- **Comment threads on inspections** — nice-to-have, not launch-critical
- **Slack/Teams notification integration** — easy later via Cloud Functions
- **Real-time collaborative editing** — Google-Docs-style. CRDT complexity not worth it for v2.

---

## 16. Parking lot (ideas that came up, unresolved)

- "Trainee mode" where a junior inspector's inspections go into a review queue before finalizing
- Per-inspector performance dashboards (avg time per inspection, client satisfaction)
- Automatic Slack post in the team channel when an inspection finalizes
- Weather / traffic integration for scheduling (leverages existing Calendar conflict detection)

---

**Next review of this doc:** When TestFlight cohort feedback surfaces meaningful demand for team features, OR when 3+ paying customers request it post-launch, whichever comes first. Do NOT start Phase 1 implementation before then.
