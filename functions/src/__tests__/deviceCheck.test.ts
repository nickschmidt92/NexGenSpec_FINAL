/**
 * Unit tests for the DeviceCheck helpers in src/index.ts.
 *
 * Covers:
 *   - signAppleJwt — deterministic header + claims when issuedAt is pinned
 *   - buildQueryBody / buildUpdateBody — exact shape Apple expects
 *   - pickAppleBase — sandbox flag parsing
 *   - callApple — fetch is mocked; verifies request shape and response parsing
 */

import { describe, it, expect, vi } from "vitest";
import { generateKeyPair, exportPKCS8, jwtVerify } from "jose";
import {
  signAppleJwt,
  buildQueryBody,
  buildUpdateBody,
  pickAppleBase,
  callApple,
  parseDeviceCheckTokenBody,
  APPLE_DC_PROD_BASE,
  APPLE_DC_SANDBOX_BASE,
  APPLE_QUERY_PATH,
  APPLE_UPDATE_PATH,
} from "../index";

// ---------------------------------------------------------------------------
// signAppleJwt
// ---------------------------------------------------------------------------

describe("signAppleJwt", () => {
  it("produces a JWT with the Apple-required header and claims", async () => {
    const { privateKey, publicKey } = await generateKeyPair("ES256");
    const pem = await exportPKCS8(privateKey);

    const issuedAt = 1_700_000_000;
    const jwt = await signAppleJwt({
      privateKeyPem: pem,
      keyId: "ABC1234567",
      teamId: "CPTLCQYSJJ",
      issuedAt,
    });

    // Decode header without verification — we want to assert kid/alg.
    const [headerB64] = jwt.split(".");
    const header = JSON.parse(
      Buffer.from(headerB64, "base64url").toString("utf-8")
    ) as { alg: string; kid: string; typ?: string };
    expect(header.alg).toBe("ES256");
    expect(header.kid).toBe("ABC1234567");

    // Verify signature + claims with the public key.
    const { payload } = await jwtVerify(jwt, publicKey);
    expect(payload.iss).toBe("CPTLCQYSJJ");
    expect(payload.iat).toBe(issuedAt);
    // Apple spec: no `exp` claim.
    expect(payload.exp).toBeUndefined();
  });

  it("defaults issuedAt to now() when not provided", async () => {
    const { privateKey, publicKey } = await generateKeyPair("ES256");
    const pem = await exportPKCS8(privateKey);

    const before = Math.floor(Date.now() / 1000);
    const jwt = await signAppleJwt({
      privateKeyPem: pem,
      keyId: "KEY1234567",
      teamId: "TEAM123456",
    });
    const after = Math.floor(Date.now() / 1000);

    const { payload } = await jwtVerify(jwt, publicKey);
    expect(payload.iat).toBeGreaterThanOrEqual(before);
    expect(payload.iat).toBeLessThanOrEqual(after);
  });
});

// ---------------------------------------------------------------------------
// buildQueryBody / buildUpdateBody
// ---------------------------------------------------------------------------

describe("buildQueryBody", () => {
  it("uses provided transactionId and timestamp verbatim", () => {
    const body = buildQueryBody({
      deviceToken: "abc==",
      transactionId: "txn-1",
      timestamp: 1234,
    });
    expect(body).toEqual({
      device_token: "abc==",
      transaction_id: "txn-1",
      timestamp: 1234,
    });
  });

  it("auto-fills transactionId (uuid) and timestamp (now in ms)", () => {
    const before = Date.now();
    const body = buildQueryBody({ deviceToken: "tok" });
    const after = Date.now();

    expect(body.device_token).toBe("tok");
    expect(body.transaction_id).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    );
    expect(body.timestamp).toBeGreaterThanOrEqual(before);
    expect(body.timestamp).toBeLessThanOrEqual(after);
  });
});

describe("buildUpdateBody", () => {
  it("includes bit0 and bit1 alongside the query fields", () => {
    const body = buildUpdateBody({
      deviceToken: "tok",
      bit0: true,
      bit1: false,
      transactionId: "txn-2",
      timestamp: 999,
    });
    expect(body).toEqual({
      device_token: "tok",
      transaction_id: "txn-2",
      timestamp: 999,
      bit0: true,
      bit1: false,
    });
  });
});

// ---------------------------------------------------------------------------
// pickAppleBase
// ---------------------------------------------------------------------------

describe("pickAppleBase", () => {
  it("returns sandbox URL when flag is 'true' (case-insensitive)", () => {
    expect(pickAppleBase("true")).toBe(APPLE_DC_SANDBOX_BASE);
    expect(pickAppleBase("TRUE")).toBe(APPLE_DC_SANDBOX_BASE);
    expect(pickAppleBase("True")).toBe(APPLE_DC_SANDBOX_BASE);
  });

  it("returns prod URL otherwise", () => {
    expect(pickAppleBase("false")).toBe(APPLE_DC_PROD_BASE);
    expect(pickAppleBase("")).toBe(APPLE_DC_PROD_BASE);
    expect(pickAppleBase("yes")).toBe(APPLE_DC_PROD_BASE);
  });
});

// ---------------------------------------------------------------------------
// callApple — fetch mocked
// ---------------------------------------------------------------------------

function mockFetch(
  fn: (url: string, init: RequestInit) => Promise<Response>
): typeof fetch {
  return vi.fn(fn) as unknown as typeof fetch;
}

describe("callApple — query", () => {
  it("sends POST to <base><path> with JWT and JSON body", async () => {
    const captured: { url?: string; init?: RequestInit } = {};
    const fetchImpl = mockFetch(async (url, init) => {
      captured.url = url;
      captured.init = init;
      return new Response(JSON.stringify({ bit0: true, bit1: false }), {
        status: 200,
      });
    });

    const body = buildQueryBody({
      deviceToken: "TOKEN",
      transactionId: "txn-x",
      timestamp: 1,
    });

    const result = await callApple({
      base: APPLE_DC_SANDBOX_BASE,
      path: APPLE_QUERY_PATH,
      body,
      jwt: "JWT.HERE",
      fetchImpl,
    });

    expect(captured.url).toBe(`${APPLE_DC_SANDBOX_BASE}${APPLE_QUERY_PATH}`);
    expect(captured.init?.method).toBe("POST");
    const headers = captured.init?.headers as Record<string, string>;
    expect(headers.Authorization).toBe("Bearer JWT.HERE");
    expect(headers["Content-Type"]).toBe("application/json");
    expect(JSON.parse(captured.init?.body as string)).toEqual(body);

    expect(result).toEqual({
      kind: "ok",
      bits: { bit0: true, bit1: false },
    });
  });

  it("treats empty 200 response as bits all-false (device not yet recorded)", async () => {
    const fetchImpl = mockFetch(
      async () => new Response("", { status: 200 })
    );
    const result = await callApple({
      base: APPLE_DC_PROD_BASE,
      path: APPLE_QUERY_PATH,
      body: buildQueryBody({ deviceToken: "T", transactionId: "x", timestamp: 1 }),
      jwt: "j",
      fetchImpl,
    });
    expect(result).toEqual({ kind: "ok", bits: { bit0: false, bit1: false } });
  });

  it("treats non-JSON 200 response as bits all-false", async () => {
    const fetchImpl = mockFetch(
      async () =>
        new Response("Failed to find bit state", { status: 200 })
    );
    const result = await callApple({
      base: APPLE_DC_PROD_BASE,
      path: APPLE_QUERY_PATH,
      body: buildQueryBody({ deviceToken: "T", transactionId: "x", timestamp: 1 }),
      jwt: "j",
      fetchImpl,
    });
    expect(result).toEqual({ kind: "ok", bits: { bit0: false, bit1: false } });
  });

  it("returns rejected on non-2xx", async () => {
    const fetchImpl = mockFetch(
      async () => new Response("bad token", { status: 401 })
    );
    const result = await callApple({
      base: APPLE_DC_PROD_BASE,
      path: APPLE_QUERY_PATH,
      body: buildQueryBody({ deviceToken: "T", transactionId: "x", timestamp: 1 }),
      jwt: "j",
      fetchImpl,
    });
    expect(result).toEqual({
      kind: "rejected",
      status: 401,
      body: "bad token",
    });
  });
});

describe("callApple — update", () => {
  it("treats 200 (any body) as ok with bits=null", async () => {
    const fetchImpl = mockFetch(
      async () => new Response("", { status: 200 })
    );
    const result = await callApple({
      base: APPLE_DC_PROD_BASE,
      path: APPLE_UPDATE_PATH,
      body: buildUpdateBody({
        deviceToken: "T",
        bit0: true,
        bit1: false,
        transactionId: "x",
        timestamp: 1,
      }),
      jwt: "j",
      fetchImpl,
    });
    expect(result).toEqual({ kind: "ok", bits: null });
  });

  it("returns rejected on non-2xx", async () => {
    const fetchImpl = mockFetch(
      async () => new Response("Bad device token", { status: 400 })
    );
    const result = await callApple({
      base: APPLE_DC_PROD_BASE,
      path: APPLE_UPDATE_PATH,
      body: buildUpdateBody({
        deviceToken: "T",
        bit0: true,
        bit1: false,
        transactionId: "x",
        timestamp: 1,
      }),
      jwt: "j",
      fetchImpl,
    });
    expect(result).toEqual({
      kind: "rejected",
      status: 400,
      body: "Bad device token",
    });
  });
});

// ---------------------------------------------------------------------------
// parseDeviceCheckTokenBody — HTTP body contract with the real client.
//
// REGRESSION GUARD: the client (DeviceCheckTrialGate.swift) posts the token
// under the key `deviceToken`, but the parser originally read only
// `deviceCheckToken`, so every request 400'd and the DeviceCheck reinstall
// backstop silently failed open — invisible for weeks because the failure had
// no symptom and the old tests exercised buildQueryBody() directly, never this
// HTTP parser. These tests feed the ACTUAL client payload shape through the
// parser so a field-name drift can never ship unnoticed again.
// ---------------------------------------------------------------------------

describe("parseDeviceCheckTokenBody", () => {
  // Derive the param type from the function so we don't need to import Request.
  type Req = Parameters<typeof parseDeviceCheckTokenBody>[0];
  const mkReq = (method: string, body: unknown): Req =>
    ({ method, body } as unknown as Req);

  it("accepts the real shipped client payload: { deviceToken }", () => {
    // This is exactly what DeviceCheckTrialGate.swift sends. If this ever fails,
    // production trial enforcement is broken (fails open) — do not weaken it.
    const result = parseDeviceCheckTokenBody(mkReq("POST", { deviceToken: "tok123" }));
    expect(result).toEqual({ ok: true, deviceCheckToken: "tok123" });
  });

  it("accepts the canonical key: { deviceCheckToken }", () => {
    const result = parseDeviceCheckTokenBody(mkReq("POST", { deviceCheckToken: "tok123" }));
    expect(result).toEqual({ ok: true, deviceCheckToken: "tok123" });
  });

  it("rejects a body with neither key", () => {
    const result = parseDeviceCheckTokenBody(mkReq("POST", { somethingElse: "x" }));
    expect(result.ok).toBe(false);
    expect(result.reason).toBe("deviceCheckToken_missing_or_invalid");
  });

  it("rejects an empty-string token", () => {
    const result = parseDeviceCheckTokenBody(mkReq("POST", { deviceToken: "" }));
    expect(result.ok).toBe(false);
  });

  it("rejects a non-object body", () => {
    const result = parseDeviceCheckTokenBody(mkReq("POST", undefined));
    expect(result.ok).toBe(false);
    expect(result.reason).toBe("body_not_object");
  });

  it("rejects a non-POST method", () => {
    const result = parseDeviceCheckTokenBody(mkReq("GET", { deviceToken: "tok123" }));
    expect(result.ok).toBe(false);
    expect(result.reason).toBe("method_not_allowed");
  });
});
