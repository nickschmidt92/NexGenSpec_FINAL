# DeviceCheck Setup Runbook (NexGenSpec)

Operator guide for wiring Apple DeviceCheck into the NexGenSpec iOS app and its Firebase Cloud Functions backend.

- **App bundle:** `com.nexgenspec.app`
- **Apple Team ID:** `CPTLCQYSJJ`
- **Firebase project:** `nexgenspec-prod`
- **Backend:** `~/Documents/NexGenSpec_FINAL/functions/`

---

## 1. What this is + why

Apple DeviceCheck is a free Apple-hosted service that lets your backend store **2 bits of state per physical device** (4 possible values), keyed to the device hardware itself rather than to an Apple ID, an iCloud account, or local storage. Those bits live on Apple's servers, survive app deletion + reinstall, survive iOS upgrades, and cannot be wiped by the user without selling the device.

NexGenSpec uses DeviceCheck to enforce the 3-free-inspection trial limit. Without it, anyone could delete the app, reinstall, sign up with a new email, and reset the counter — effectively unlimited free inspections. With DeviceCheck, once a device has burned its 3 trial slots, the bits stay flipped forever; reinstalling the app and signing in with a different Apple ID still hits the paywall.

The user-visible effect is **none**. There is no permission prompt, no UI, no setup flow. DeviceCheck runs silently inside Cloud Functions when the iOS client requests trial status or marks a trial used. If Apple's servers are unreachable or return an error, the iOS client falls back to its local trial counter (degrades gracefully — see the iOS agent's spec for fallback policy).

---

## 2. Prerequisites

- macOS with Xcode 16+ (for the iOS client build)
- Apple Developer account with **admin** access to Team `CPTLCQYSJJ` (you must be able to create Keys, not just download profiles)
- Firebase project `nexgenspec-prod` with **Owner** or **Editor** role
- Node.js 20+ and npm (`brew install node@20`)
- Firebase CLI (`npm install -g firebase-tools`)
- An iPad with the latest dev build of NexGenSpec installed for validation

Verify before continuing:

```
node --version    # expect v20.x.x or higher
npm --version
firebase --version
```

---

## 3. One-time Apple Developer portal setup

Do this exactly once per environment. You will not be able to re-download the key file after closing the dialog — Apple shows it to you a single time.

1. Go to https://developer.apple.com → **Certificates, Identifiers & Profiles** → **Keys** → click the blue **+** button.
2. **Key Name:** `NexGenSpec DeviceCheck`. Check the box for **DeviceCheck**. Click **Continue** → **Register**.
3. **Download the .p8 file.** Apple will only let you download this file one time. Note the **Key ID** displayed on the screen — it is exactly 10 alphanumeric characters (e.g. `ABC123DEF4`). Write it down before closing the page.
4. Move the downloaded file into the secrets store and lock it down:

   ```
   mv ~/Downloads/AuthKey_<KeyID>.p8 ~/Documents/nickos-secrets/AuthKey_<KeyID>_DeviceCheck.p8
   chmod 600 ~/Documents/nickos-secrets/AuthKey_<KeyID>_DeviceCheck.p8
   ```

   Replace `<KeyID>` in both filenames with the actual 10-char ID from step 3.

5. Confirm the **Team ID**. It is `CPTLCQYSJJ` for NexGenSpec. (Apple shows it in the top-right of every page in the Developer portal.)

You should now have a `.p8` file at `~/Documents/nickos-secrets/AuthKey_<KeyID>_DeviceCheck.p8`, mode `600`, plus the Key ID written down.

---

## 4. Firebase project setup

1. Open https://console.firebase.google.com → select **nexgenspec-prod** → **Functions** tab.
2. If Functions has never been enabled on this project, click **Get started** and accept the prompts. When asked for a default region, choose **`us-central1`** (matches what the backend agent uses in its `defineSecret` and region declarations).
3. In your terminal:

   ```
   cd ~/Documents/NexGenSpec_FINAL
   firebase login                 # only if not already logged in
   firebase use nexgenspec-prod
   ```

   Expected output of `firebase use`:

   ```
   Now using project nexgenspec-prod
   ```

4. Confirm the Functions source directory exists (the backend agent creates this; it should not be empty):

   ```
   ls ~/Documents/NexGenSpec_FINAL/functions/
   ```

   You should see at least `package.json`, `tsconfig.json`, and a `src/` folder. If empty, the backend agent has not finished — wait for them or ping them.

5. Install dependencies:

   ```
   cd ~/Documents/NexGenSpec_FINAL/functions
   npm install
   ```

   Expected output ends with something like `added N packages in Xs` and **0 vulnerabilities** (or only low-severity items).

---

## 5. Configure secrets

The Cloud Function code declares four secrets via `defineSecret(...)`. You must set all four before deploying or the deploy will fail with a `Secret not found` error.

| Secret name                       | Value                                                            |
|-----------------------------------|------------------------------------------------------------------|
| `APPLE_DEVICECHECK_KEY`           | Full PEM contents of the `.p8` file (multi-line, includes header)|
| `APPLE_DEVICECHECK_KEY_ID`        | The 10-char Key ID from §3 step 3                                |
| `APPLE_TEAM_ID`                   | `CPTLCQYSJJ`                                                     |
| `APPLE_DEVICECHECK_USE_SANDBOX`   | `false` for prod / TestFlight, `true` only for local dev testing |

Set each one using Firebase Functions Secret Manager. The first command pipes the `.p8` file directly in (so you don't have to copy-paste a multi-line PEM). The other three prompt interactively.

```
firebase functions:secrets:set APPLE_DEVICECHECK_KEY < ~/Documents/nickos-secrets/AuthKey_<KeyID>_DeviceCheck.p8
firebase functions:secrets:set APPLE_DEVICECHECK_KEY_ID
firebase functions:secrets:set APPLE_TEAM_ID
firebase functions:secrets:set APPLE_DEVICECHECK_USE_SANDBOX
```

For each interactive prompt, paste the value and press Enter:

- `APPLE_DEVICECHECK_KEY_ID` — the 10-char Key ID
- `APPLE_TEAM_ID` — `CPTLCQYSJJ`
- `APPLE_DEVICECHECK_USE_SANDBOX` — `false`

Each command prints something like:

```
Created a new secret version projects/123456789/secrets/APPLE_TEAM_ID/versions/1
```

Verify all four are stored:

```
firebase functions:secrets:access APPLE_DEVICECHECK_KEY_ID
firebase functions:secrets:access APPLE_TEAM_ID
firebase functions:secrets:access APPLE_DEVICECHECK_USE_SANDBOX
```

Each prints the stored value to stdout. **Do not** run `:access` on `APPLE_DEVICECHECK_KEY` casually — it dumps the private key. If you must, redirect to a file with mode 600 and delete it after.

---

## 6. Deploy

```
cd ~/Documents/NexGenSpec_FINAL/functions
npm run build
firebase deploy --only functions
```

Expected output (last lines):

```
+  functions[us-central1-getTrialStatus]: Successful create operation.
+  functions[us-central1-markTrialUsed]: Successful create operation.

Function URL (getTrialStatus(us-central1)): https://us-central1-nexgenspec-prod.cloudfunctions.net/getTrialStatus
Function URL (markTrialUsed(us-central1)): https://us-central1-nexgenspec-prod.cloudfunctions.net/markTrialUsed

+  Deploy complete!
```

Confirm both endpoints are live:

```
curl -I https://us-central1-nexgenspec-prod.cloudfunctions.net/getTrialStatus
curl -I https://us-central1-nexgenspec-prod.cloudfunctions.net/markTrialUsed
```

You should see HTTP `401` or `403` (auth required) — that is correct. A `404` means the function did not deploy.

---

## 7. Validation

Do this on a real iPad with the latest NexGenSpec dev build installed. The simulator does **not** support DeviceCheck — Apple will return `Bit State Not Found` or `Forbidden` for simulator devices, which is normal but doesn't validate end-to-end.

1. Open the app, sign in. Then open **Files → On My iPad → NexGenSpec → audit_log.txt** and look for a line resembling:

   ```
   DeviceCheck refresh result: unused
   ```

   (Confirm exact log wording with the iOS agent — it may be `DC: state=unused` or similar.)

2. Burn through 3 free inspections. Each one should produce an audit log entry:

   ```
   DeviceCheck markTrialUsed succeeded
   ```

3. After the third inspection, the next attempt should hit the paywall.

4. Delete the app from the iPad (long-press → Remove App → Delete App). Reinstall via Xcode or TestFlight. Sign in again — same Apple ID is fine.

5. Try to create an inspection. **Expected:** paywall appears immediately, no free inspections offered. Audit log should show:

   ```
   DeviceCheck refresh result: used
   ```

If any of those four checkpoints fail, jump to §8.

---

## 8. Troubleshooting

**`401 Unauthorized` or `Forbidden` from Apple**
The Function is signing the JWT to Apple but Apple rejects it. Almost always one of: wrong Key ID, wrong Team ID, or a corrupted `.p8` upload (extra whitespace, missing PEM headers).

```
firebase functions:secrets:access APPLE_DEVICECHECK_KEY_ID
firebase functions:secrets:access APPLE_TEAM_ID
```

Compare against the Apple Developer portal Keys page. Re-upload the key with the redirect form in §5 if in doubt.

**`Bit State Not Found` on first call**
Apple has not initialized bits for this physical device yet — this is **expected** the first time a device contacts your Function. The backend should treat this as `unused` (zero state) and return that to the client. Confirm with the backend agent that this branch is handled. If you see this error surface to the iOS app, the backend is incorrectly propagating it instead of mapping to `unused`.

**Sandbox vs prod endpoints**
Apple has two DeviceCheck hosts:
- `api.development.devicecheck.apple.com` — sandbox
- `api.devicecheck.apple.com` — production

TestFlight builds, App Store builds, **and Xcode dev installs on a real device** all hit the production endpoint. The sandbox endpoint is essentially only useful for backend integration tests with a stubbed device token. **Set `APPLE_DEVICECHECK_USE_SANDBOX=false` for any user-facing build.** If validation in §7 returns "Bit State Not Found" forever and never flips, you may have left this on `true`.

**Function deployed but iOS can't reach it**
Check the iOS app's `GoogleService-Info.plist` is the one for `nexgenspec-prod` (not a dev project). Check the Functions log for cold-start errors:

```
firebase functions:log --only getTrialStatus,markTrialUsed
```

**Secret update did not take effect**
Functions cache secret values per-instance. After running `secrets:set`, redeploy:

```
firebase deploy --only functions
```

A redeploy forces all instances to reload secrets.

---

## 9. Cost / quota

- **Cloud Functions:** Each inspector triggers `getTrialStatus` once at sign-in and `markTrialUsed` up to 3 times in their lifetime, then never again (post-paywall their state is fixed). For NexGenSpec's expected scale this is well inside the Firebase Spark (free) tier — 2M invocations/month free, 400K GB-seconds/month free.
- **Apple DeviceCheck:** Free. No published rate limit for normal usage. (Apple's docs note throttling on abusive patterns but do not specify a number; one call per inspection is nowhere near abusive.)
- **Egress:** Negligible. Each call exchanges a few hundred bytes with Apple.

No billing alarms needed at current scale. If NexGenSpec ever grows beyond ~100K active inspectors, revisit.

---

## 10. Rotation procedure

If the `.p8` key leaks, is committed to git, or is otherwise compromised:

1. **Revoke immediately.** Apple Developer portal → **Keys** → click the compromised key → **Revoke**. Apple stops accepting JWTs signed with it instantly.
2. **Generate a new DeviceCheck key.** Repeat all of §3 with a new key (e.g. name it `NexGenSpec DeviceCheck v2`). Save the new `.p8` to `~/Documents/nickos-secrets/AuthKey_<NewKeyID>_DeviceCheck.p8`, chmod 600.
3. **Update both secrets** (the key file and the Key ID — they're a pair):

   ```
   firebase functions:secrets:set APPLE_DEVICECHECK_KEY < ~/Documents/nickos-secrets/AuthKey_<NewKeyID>_DeviceCheck.p8
   firebase functions:secrets:set APPLE_DEVICECHECK_KEY_ID
   ```

4. **Redeploy** to push the new secret versions to running instances:

   ```
   cd ~/Documents/NexGenSpec_FINAL/functions
   firebase deploy --only functions
   ```

5. **Existing device bits remain valid.** DeviceCheck bits are scoped per-device, per-app (per Team ID + Bundle ID), not per-key. Rotating the key does **not** reset any user's trial state. Inspectors who already burned their 3 inspections stay on the paywall; those mid-trial keep their remaining count.

6. **Delete the old `.p8`** from `~/Documents/nickos-secrets/` once you've confirmed the new one works in production.

---

**End of runbook.** Questions or failures during setup: cross-check against the backend agent's Function code (`~/Documents/NexGenSpec_FINAL/functions/src/`) and the iOS agent's DeviceCheck client integration before filing a bug.
