# NexGenSpec Cloud Functions — Apple DeviceCheck

Firebase Cloud Functions (v2, TypeScript, Node 20) backing NexGenSpec's
3-free-inspection trial. Apple DeviceCheck stores 2 bits per device that
survive app deletion and reinstall, so the trial cap can't be reset by
wiping the app.

bit0 = "trial used". bit1 = reserved.

## Endpoints

Both are HTTPS endpoints. The iOS client must include a Firebase Auth ID
token: `Authorization: Bearer <id-token>`.

### `POST getTrialStatus`

```jsonc
// request
{ "deviceCheckToken": "<base64 from DCDevice.generateToken>" }

// response
{ "trialUsed": true | false }
```

### `POST markTrialUsed`

```jsonc
// request
{ "deviceCheckToken": "<base64 from DCDevice.generateToken>" }

// response
{ "ok": true }
```

### Error responses

| Status | When |
| --- | --- |
| 400 | Body missing/invalid `deviceCheckToken` |
| 401 | Missing/invalid Firebase ID token |
| 502 | Apple DeviceCheck rejected the request — payload includes `appleStatus` and `appleBody` |
| 500 | Internal error (key import failed, network blow-up, etc.) |

## Install

```bash
cd functions
npm install
```

## Test

```bash
npm test
```

Vitest covers JWT signing (header + claims, signature verifies with the
matching public key), Apple request body builders, sandbox-flag parsing,
and the Apple call helper with `fetch` mocked.

## Build

```bash
npm run build
```

## Required secrets

Set these in Firebase Secret Manager before deploying — the functions
load them at runtime via `defineSecret`:

| Secret | Value |
| --- | --- |
| `APPLE_DEVICECHECK_KEY` | Full PEM contents of the `.p8` private key downloaded from the Apple Developer portal (DeviceCheck-enabled key) |
| `APPLE_DEVICECHECK_KEY_ID` | The 10-char Key ID Apple shows next to that key |
| `APPLE_TEAM_ID` | The 10-char Apple Team ID (`CPTLCQYSJJ` for NexGenSpec) |
| `APPLE_DEVICECHECK_USE_SANDBOX` | `"true"` while testing, `"false"` for production |

```bash
firebase functions:secrets:set APPLE_DEVICECHECK_KEY < /path/to/AuthKey_XXXX.p8
firebase functions:secrets:set APPLE_DEVICECHECK_KEY_ID
firebase functions:secrets:set APPLE_TEAM_ID
firebase functions:secrets:set APPLE_DEVICECHECK_USE_SANDBOX
```

## Deploy

```bash
npm run deploy
# == firebase deploy --only functions
```

## Sandbox vs prod

Apple runs DeviceCheck on two distinct hosts:

- Sandbox: `https://api.development.devicecheck.apple.com`
- Production: `https://api.devicecheck.apple.com`

Tokens generated on a Debug build of the iOS app are only valid against
sandbox; tokens from a TestFlight or App Store build are only valid
against production. Flip `APPLE_DEVICECHECK_USE_SANDBOX` accordingly.
Mismatched host vs token returns a 400 from Apple, which surfaces as a
502 from these functions.

## JWT signing flow

Every Apple call is server-to-server authenticated with an ES256 JWT:

```
header  = { alg: "ES256", kid: <APPLE_DEVICECHECK_KEY_ID> }
payload = { iss: <APPLE_TEAM_ID>, iat: <unix-seconds-now> }
signed with the .p8 private key (PEM, PKCS8)
```

Apple does not honor `exp` — it enforces a 1-hour max from `iat`. We
mint a fresh token per request to keep things simple; if cold-start cost
becomes an issue we can cache for ~50 minutes per warm instance.

## File layout

```
functions/
  src/
    index.ts                    # endpoints + helpers (all exported for tests)
    __tests__/
      deviceCheck.test.ts       # vitest unit tests
  package.json
  tsconfig.json
  .gitignore
  README.md
```
