/**
 * NexGenSpec Cloud Functions — Apple DeviceCheck trial enforcement.
 *
 * Two HTTPS endpoints (Firebase Functions v2):
 *   - getTrialStatus: queries Apple DeviceCheck to read bit0 ("trial used")
 *   - markTrialUsed:  updates Apple DeviceCheck to set  bit0 = true
 *
 * Both endpoints require a valid Firebase ID token in the
 * `Authorization: Bearer <token>` header.
 */

import { onRequest, HttpsOptions, Request } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import { logger } from "firebase-functions/v2";
import * as admin from "firebase-admin";
import { importPKCS8, SignJWT } from "jose";
import { randomUUID } from "node:crypto";
import type { Response } from "express";

// ---------------------------------------------------------------------------
// Secrets — pulled at runtime via defineSecret. Never read process.env directly
// for these.
// ---------------------------------------------------------------------------

const APPLE_DEVICECHECK_KEY = defineSecret("APPLE_DEVICECHECK_KEY");
const APPLE_DEVICECHECK_KEY_ID = defineSecret("APPLE_DEVICECHECK_KEY_ID");
const APPLE_TEAM_ID = defineSecret("APPLE_TEAM_ID");
const APPLE_DEVICECHECK_USE_SANDBOX = defineSecret(
  "APPLE_DEVICECHECK_USE_SANDBOX"
);

// ---------------------------------------------------------------------------
// Admin SDK init (idempotent — Cloud Functions cold-start safe).
// ---------------------------------------------------------------------------

if (admin.apps.length === 0) {
  admin.initializeApp();
}

// ---------------------------------------------------------------------------
// Apple DeviceCheck constants
// ---------------------------------------------------------------------------

export const APPLE_DC_PROD_BASE = "https://api.devicecheck.apple.com";
export const APPLE_DC_SANDBOX_BASE = "https://api.development.devicecheck.apple.com";

export const APPLE_QUERY_PATH = "/v1/query_two_bits";
export const APPLE_UPDATE_PATH = "/v1/update_two_bits";

// ---------------------------------------------------------------------------
// JWT signing — Apple DeviceCheck server-to-server auth.
//
// Spec:
//   header  = { alg: "ES256", kid: <KeyID> }
//   payload = { iss: <TeamID>, iat: <unix-seconds> }
//   No `exp` — Apple enforces a 1h max from `iat`.
// ---------------------------------------------------------------------------

export interface SignAppleJwtArgs {
  /** PEM-encoded ES256 private key (.p8 contents). */
  privateKeyPem: string;
  /** 10-character Apple Key ID. */
  keyId: string;
  /** 10-character Apple Team ID. */
  teamId: string;
  /** Issued-at, unix seconds. Defaults to now(). Injectable for tests. */
  issuedAt?: number;
}

/**
 * Sign a DeviceCheck-compatible JWT (ES256). Deterministic when `issuedAt` is
 * supplied — tests pin it.
 */
export async function signAppleJwt(args: SignAppleJwtArgs): Promise<string> {
  const { privateKeyPem, keyId, teamId, issuedAt } = args;
  const iat = issuedAt ?? Math.floor(Date.now() / 1000);

  const key = await importPKCS8(privateKeyPem, "ES256");

  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt(iat)
    .sign(key);

  return jwt;
}

// ---------------------------------------------------------------------------
// Apple request body builders — pulled out so they're trivially unit-testable.
// ---------------------------------------------------------------------------

export interface AppleQueryBody {
  device_token: string;
  transaction_id: string;
  timestamp: number;
}

export interface AppleUpdateBody extends AppleQueryBody {
  bit0: boolean;
  bit1: boolean;
}

/** Build the JSON body for Apple's `query_two_bits` endpoint. */
export function buildQueryBody(args: {
  deviceToken: string;
  transactionId?: string;
  timestamp?: number;
}): AppleQueryBody {
  return {
    device_token: args.deviceToken,
    transaction_id: args.transactionId ?? randomUUID(),
    timestamp: args.timestamp ?? Date.now(),
  };
}

/** Build the JSON body for Apple's `update_two_bits` endpoint. */
export function buildUpdateBody(args: {
  deviceToken: string;
  bit0: boolean;
  bit1: boolean;
  transactionId?: string;
  timestamp?: number;
}): AppleUpdateBody {
  return {
    device_token: args.deviceToken,
    transaction_id: args.transactionId ?? randomUUID(),
    timestamp: args.timestamp ?? Date.now(),
    bit0: args.bit0,
    bit1: args.bit1,
  };
}

/** Pick the Apple base URL from the sandbox flag string ("true"/"false"). */
export function pickAppleBase(useSandboxFlag: string): string {
  return useSandboxFlag.toLowerCase() === "true"
    ? APPLE_DC_SANDBOX_BASE
    : APPLE_DC_PROD_BASE;
}

// ---------------------------------------------------------------------------
// Apple call helper. Returns either:
//   - { kind: "ok",     bits: { bit0, bit1 } | null }   // null = update (no body)
//   - { kind: "rejected", status, body }                // Apple non-2xx — surface as 502
//   - throws on network error                           // bubbled as 500
//
// Apple's query response on "device never been recorded" is HTTP 200 with an
// empty body — we treat that as bits all-false.
// ---------------------------------------------------------------------------

export type AppleCallResult =
  | { kind: "ok"; bits: { bit0: boolean; bit1: boolean } | null }
  | { kind: "rejected"; status: number; body: string };

export interface CallAppleArgs {
  base: string;
  path: typeof APPLE_QUERY_PATH | typeof APPLE_UPDATE_PATH;
  body: AppleQueryBody | AppleUpdateBody;
  jwt: string;
  /** Override fetch — for tests. */
  fetchImpl?: typeof fetch;
}

export async function callApple(args: CallAppleArgs): Promise<AppleCallResult> {
  const fetchImpl = args.fetchImpl ?? fetch;

  const res = await fetchImpl(`${args.base}${args.path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${args.jwt}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args.body),
  });

  // Update endpoint: 200 with empty body on success.
  if (args.path === APPLE_UPDATE_PATH) {
    if (res.ok) return { kind: "ok", bits: null };
    return { kind: "rejected", status: res.status, body: await res.text() };
  }

  // Query endpoint.
  if (!res.ok) {
    return { kind: "rejected", status: res.status, body: await res.text() };
  }

  const text = await res.text();
  if (text.trim().length === 0) {
    // Device never recorded — Apple returns empty. Treat as all-false.
    return { kind: "ok", bits: { bit0: false, bit1: false } };
  }

  // Apple returns either JSON {bit0, bit1, last_update_time} or a status string
  // like "Failed to find bit state" wrapped in a 200. Try JSON first.
  try {
    const parsed = JSON.parse(text) as { bit0?: boolean; bit1?: boolean };
    return {
      kind: "ok",
      bits: {
        bit0: Boolean(parsed.bit0),
        bit1: Boolean(parsed.bit1),
      },
    };
  } catch {
    // Non-JSON 200 = "no bits recorded yet"
    return { kind: "ok", bits: { bit0: false, bit1: false } };
  }
}

// ---------------------------------------------------------------------------
// Auth: Firebase ID token verification.
// ---------------------------------------------------------------------------

interface AuthResult {
  ok: boolean;
  uid?: string;
  reason?: string;
}

async function verifyFirebaseAuth(req: Request): Promise<AuthResult> {
  const header = req.get("authorization") ?? req.get("Authorization");
  if (!header || !header.startsWith("Bearer ")) {
    return { ok: false, reason: "missing_bearer_token" };
  }
  const idToken = header.slice("Bearer ".length).trim();
  if (!idToken) {
    return { ok: false, reason: "empty_bearer_token" };
  }
  try {
    const decoded = await admin.auth().verifyIdToken(idToken);
    return { ok: true, uid: decoded.uid };
  } catch (e) {
    return { ok: false, reason: (e as Error).message };
  }
}

// ---------------------------------------------------------------------------
// Request validation
// ---------------------------------------------------------------------------

interface ParsedBody {
  ok: boolean;
  deviceCheckToken?: string;
  reason?: string;
}

function parseDeviceCheckTokenBody(req: Request): ParsedBody {
  if (req.method !== "POST") {
    return { ok: false, reason: "method_not_allowed" };
  }
  const body = req.body as
    | { deviceCheckToken?: unknown; deviceToken?: unknown }
    | undefined;
  if (!body || typeof body !== "object") {
    return { ok: false, reason: "body_not_object" };
  }
  // Accept both keys: shipped clients (through build 11) send `deviceToken`,
  // newer clients send the canonical `deviceCheckToken`. Without accepting
  // `deviceToken`, every request 400s and the DeviceCheck reinstall backstop
  // silently fails open (the local UserDefaults counter becomes the only gate).
  const token = body.deviceCheckToken ?? body.deviceToken;
  if (typeof token !== "string" || token.length === 0) {
    return { ok: false, reason: "deviceCheckToken_missing_or_invalid" };
  }
  return { ok: true, deviceCheckToken: token };
}

// ---------------------------------------------------------------------------
// Shared function options — all secrets bound, modest memory.
// ---------------------------------------------------------------------------

const SHARED_OPTIONS: HttpsOptions = {
  region: "us-central1",
  memory: "256MiB",
  timeoutSeconds: 30,
  secrets: [
    APPLE_DEVICECHECK_KEY,
    APPLE_DEVICECHECK_KEY_ID,
    APPLE_TEAM_ID,
    APPLE_DEVICECHECK_USE_SANDBOX,
  ],
};

// ---------------------------------------------------------------------------
// Endpoint helpers
// ---------------------------------------------------------------------------

function send(
  res: Response,
  status: number,
  body: Record<string, unknown>
): void {
  res.status(status).json(body);
}

async function getSignedJwt(): Promise<string> {
  return signAppleJwt({
    privateKeyPem: APPLE_DEVICECHECK_KEY.value(),
    keyId: APPLE_DEVICECHECK_KEY_ID.value(),
    teamId: APPLE_TEAM_ID.value(),
  });
}

// ---------------------------------------------------------------------------
// getTrialStatus
// ---------------------------------------------------------------------------

export const getTrialStatus = onRequest(SHARED_OPTIONS, async (req, res) => {
  const auth = await verifyFirebaseAuth(req);
  if (!auth.ok) {
    return send(res, 401, { error: "unauthorized", reason: auth.reason });
  }

  const parsed = parseDeviceCheckTokenBody(req);
  if (!parsed.ok || !parsed.deviceCheckToken) {
    return send(res, 400, { error: "bad_request", reason: parsed.reason });
  }

  try {
    const jwt = await getSignedJwt();
    const base = pickAppleBase(APPLE_DEVICECHECK_USE_SANDBOX.value());
    const body = buildQueryBody({ deviceToken: parsed.deviceCheckToken });

    const result = await callApple({
      base,
      path: APPLE_QUERY_PATH,
      body,
      jwt,
    });

    if (result.kind === "rejected") {
      logger.warn("Apple DeviceCheck query rejected", {
        uid: auth.uid,
        status: result.status,
        body: result.body,
      });
      return send(res, 502, {
        error: "apple_devicecheck_rejected",
        appleStatus: result.status,
        appleBody: result.body,
      });
    }

    const trialUsed = Boolean(result.bits?.bit0);
    return send(res, 200, { trialUsed });
  } catch (e) {
    logger.error("getTrialStatus internal error", {
      uid: auth.uid,
      error: (e as Error).message,
    });
    return send(res, 500, { error: "internal" });
  }
});

// ---------------------------------------------------------------------------
// markTrialUsed
// ---------------------------------------------------------------------------

export const markTrialUsed = onRequest(SHARED_OPTIONS, async (req, res) => {
  const auth = await verifyFirebaseAuth(req);
  if (!auth.ok) {
    return send(res, 401, { error: "unauthorized", reason: auth.reason });
  }

  const parsed = parseDeviceCheckTokenBody(req);
  if (!parsed.ok || !parsed.deviceCheckToken) {
    return send(res, 400, { error: "bad_request", reason: parsed.reason });
  }

  try {
    const jwt = await getSignedJwt();
    const base = pickAppleBase(APPLE_DEVICECHECK_USE_SANDBOX.value());
    const body = buildUpdateBody({
      deviceToken: parsed.deviceCheckToken,
      bit0: true,
      bit1: false,
    });

    const result = await callApple({
      base,
      path: APPLE_UPDATE_PATH,
      body,
      jwt,
    });

    if (result.kind === "rejected") {
      logger.warn("Apple DeviceCheck update rejected", {
        uid: auth.uid,
        status: result.status,
        body: result.body,
      });
      return send(res, 502, {
        error: "apple_devicecheck_rejected",
        appleStatus: result.status,
        appleBody: result.body,
      });
    }

    return send(res, 200, { ok: true });
  } catch (e) {
    logger.error("markTrialUsed internal error", {
      uid: auth.uid,
      error: (e as Error).message,
    });
    return send(res, 500, { error: "internal" });
  }
});
