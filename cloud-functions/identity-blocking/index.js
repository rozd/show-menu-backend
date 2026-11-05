"use strict";

// GCP Identity Platform blocking functions (beforeCreate / beforeSignIn).
// Zero-dependency HTTP function, deployed via
// `gcloud functions deploy --gen2 --trigger-http --allow-unauthenticated`.
// Wire format, security model, deploy/register commands and runbook: see README.md.
//
// This is a STUB. The policy decision lives in `decideUserClaims` below — it
// currently returns `null` (no change) for every user. Fill it in with your
// own rule (e.g. an env-driven allow-list → role claim, a domain check, a
// tenant invariant). Do not modify the JWT verification or wire-format
// helpers — they implement the Identity Platform blocking-function spec.

const crypto = require("node:crypto");
const http = require("node:http");
const https = require("node:https");

// Identity Platform rejects custom-claims payloads serializing to >1000 bytes;
// a rejection would block the user, so an oversized result is left untouched.
const MAX_CUSTOM_CLAIMS_BYTES = 1000;

// === Inbound JWT verification =================================================
// Identity Platform calls blocking functions WITHOUT an Authorization header —
// the security boundary is the JWT in the request body (`data.jwt`), signed by
// `securetoken@system.gserviceaccount.com`. Function MUST verify it; the
// Cloud Run gateway is open (`--allow-unauthenticated`). See README.md.

// Cloud Functions gen-2 / Cloud Run does NOT set GOOGLE_CLOUD_PROJECT — only
// K_SERVICE/K_REVISION/K_CONFIGURATION/PORT. Fall back to the GCE metadata
// server, which is the cross-product source of truth on Google Cloud.
const METADATA_PROJECT_ID_URL =
  "http://metadata.google.internal/computeMetadata/v1/project/project-id";
const METADATA_TIMEOUT_MS = 1500;
const ALLOWED_EVENT_TYPES = new Set(["beforeCreate", "beforeSignIn"]);
const JWT_CLOCK_SKEW_SECONDS = 60;
const JWKS_URL =
  "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";
// Bound the JWKS round trip well under the blocking-function deadline so a
// stalled endpoint never makes verification hang and fail CLOSED (blocking the
// user). The socket is destroyed on timeout so the promise always settles.
const JWKS_TIMEOUT_MS = 1500;
// Throttle SUCCESSFUL JWKS refresh to bound traffic if an attacker probes
// unknown `kid`s. A FAILED fetch uses a much shorter backoff (below) so a
// transient error doesn't poison verification for the full success interval.
const JWKS_REFRESH_MIN_INTERVAL_MS = 30_000;
const JWKS_FAILURE_BACKOFF_MS = 2_000;

let jwksFetcher = defaultJwksFetcher;     // overridable for tests
let jwksKeys = new Map();                  // kid -> KeyObject
let lastJwksFetchAttemptMs = 0;
let projectIdPromise = null;              // memoized project-ID resolver

function defaultProjectIdFromMetadata() {
  return new Promise((resolve, reject) => {
    const req = http.request(
      METADATA_PROJECT_ID_URL,
      { method: "GET", headers: { "Metadata-Flavor": "Google" }, timeout: METADATA_TIMEOUT_MS },
      (res) => {
        if (res.statusCode !== 200) {
          res.resume();
          reject(new Error(`metadata HTTP ${res.statusCode}`));
          return;
        }
        let buf = "";
        res.setEncoding("utf8");
        res.on("error", reject);
        res.on("data", (chunk) => (buf += chunk));
        res.on("end", () => {
          const id = buf.trim();
          id ? resolve(id) : reject(new Error("metadata returned empty body"));
        });
      }
    );
    req.on("timeout", () => req.destroy(new Error("metadata server timeout")));
    req.on("error", reject);
    req.end();
  });
}

let projectIdFetcher = defaultProjectIdFromMetadata;

/**
 * Resolve the GCP project ID for the `iss` check. Env vars first (cheap,
 * overridable in tests / non-GCP environments); metadata server as the runtime
 * fallback on Cloud Run / Cloud Functions gen-2 where no env var is set.
 * Memoized so we don't hit the metadata server on every sign-in.
 */
function getProjectId() {
  const fromEnv = process.env.GOOGLE_CLOUD_PROJECT || process.env.GCLOUD_PROJECT;
  if (fromEnv) return Promise.resolve(fromEnv);
  if (!projectIdPromise) {
    projectIdPromise = projectIdFetcher().catch((err) => {
      // Clear the cached rejection so a transient metadata failure doesn't
      // poison the process — the next sign-in will retry.
      projectIdPromise = null;
      throw err;
    });
  }
  return projectIdPromise;
}

function defaultJwksFetcher() {
  return new Promise((resolve, reject) => {
    const req = https.get(JWKS_URL, { timeout: JWKS_TIMEOUT_MS }, (res) => {
      if (res.statusCode !== 200) {
        res.resume();
        reject(new Error(`JWKS fetch HTTP ${res.statusCode}`));
        return;
      }
      let buf = "";
      res.setEncoding("utf8");
      res.on("error", reject);
      res.on("data", (chunk) => (buf += chunk));
      res.on("end", () => {
        try { resolve(JSON.parse(buf)); }
        catch (e) { reject(e); }
      });
    });
    req.on("timeout", () => req.destroy(new Error("JWKS fetch timeout")));
    req.on("error", reject);
  });
}

let jwksRefreshInFlight = null;            // coalesces concurrent refreshes

async function refreshJwksIfAllowed() {
  // Coalesce: concurrent cache-miss requests share one in-flight fetch.
  if (jwksRefreshInFlight) return jwksRefreshInFlight;
  // Throttle by time since the LAST SUCCESSFUL refresh (long interval) or the
  // last FAILED attempt (short backoff). Crucially the timestamp accounting is
  // resolved AFTER the fetch settles, so a transient failure consumes only the
  // short backoff — it never poisons verification for the full success window.
  const now = Date.now();
  if (now - lastJwksFetchAttemptMs < JWKS_REFRESH_MIN_INTERVAL_MS) return;
  jwksRefreshInFlight = (async () => {
    try {
      const jwks = await jwksFetcher();
      const next = new Map();
      for (const jwk of (jwks && jwks.keys) || []) {
        if (!jwk || !jwk.kid) continue;
        try {
          next.set(jwk.kid, crypto.createPublicKey({ key: jwk, format: "jwk" }));
        } catch (_) { /* skip unsupported keys */ }
      }
      jwksKeys = next;
      // Success: hold off the next refresh for the full interval.
      lastJwksFetchAttemptMs = Date.now();
    } catch (err) {
      // Failure: only back off briefly so a recovered network is retried
      // promptly, instead of consuming the full success interval.
      lastJwksFetchAttemptMs =
        Date.now() - JWKS_REFRESH_MIN_INTERVAL_MS + JWKS_FAILURE_BACKOFF_MS;
      throw err;
    } finally {
      jwksRefreshInFlight = null;
    }
  })();
  return jwksRefreshInFlight;
}

async function getPublicKey(kid) {
  if (jwksKeys.has(kid)) return jwksKeys.get(kid);
  // A refresh failure must not crash verification — fail open via the caller.
  try { await refreshJwksIfAllowed(); }
  catch (_) { /* keys remain as-is; getPublicKey returns undefined */ }
  return jwksKeys.get(kid);
}

/**
 * Verify a blocking-function inbound JWT and return the decoded payload.
 * Throws on any failure (bad shape, bad signature, bad claim) — the caller is
 * expected to log & fail-open with `{}`.
 *   - alg = RS256, signed against Google's `securetoken@system` JWKS by `kid`
 *   - iss = https://securetoken.google.com/<PROJECT_ID>
 *   - event_type ∈ { beforeCreate, beforeSignIn }
 *   - exp not in the past, iat not in the future (60s skew)
 *   - aud = expectedAudience, when one is supplied
 *
 * THE TRUST BOUNDARY is the RS256 signature over Google's `securetoken@system`
 * JWKS plus `iss` == this project. Those cannot be forged without a
 * Google-signed token for this exact project. The `aud` check is best-effort
 * defense-in-depth ONLY: if it is derived from the request `Host` header it is
 * attacker-controllable on the open (`--allow-unauthenticated`) gateway and
 * provides no real protection — pin `expectedAudience` to a configured URL
 * (FUNCTION_URL env var) at deploy time to make it meaningful.
 */
async function verifyAuthBlockingJwt(token, expectedAudience) {
  const parts = String(token).split(".");
  if (parts.length !== 3) throw new Error("malformed JWT");
  const [headerB64, payloadB64, signatureB64] = parts;

  const header = JSON.parse(Buffer.from(headerB64, "base64url").toString("utf8"));
  if (header.alg !== "RS256") throw new Error(`unsupported alg "${header.alg}"`);
  if (!header.kid) throw new Error("missing kid");

  const publicKey = await getPublicKey(header.kid);
  if (!publicKey) throw new Error(`no JWKS key for kid "${header.kid}"`);

  const signingInput = Buffer.from(`${headerB64}.${payloadB64}`, "utf8");
  const signature = Buffer.from(signatureB64, "base64url");
  if (!crypto.verify("RSA-SHA256", signingInput, publicKey, signature)) {
    throw new Error("invalid signature");
  }

  const payload = JSON.parse(Buffer.from(payloadB64, "base64url").toString("utf8"));
  const now = Math.floor(Date.now() / 1000);
  if (typeof payload.exp === "number" && payload.exp + JWT_CLOCK_SKEW_SECONDS < now) {
    throw new Error("token expired");
  }
  if (typeof payload.iat === "number" && payload.iat - JWT_CLOCK_SKEW_SECONDS > now) {
    throw new Error("token issued in future");
  }
  const projectId = await getProjectId();
  if (!projectId) throw new Error("could not resolve GCP project ID (env + metadata)");
  if (payload.iss !== `https://securetoken.google.com/${projectId}`) {
    throw new Error(`bad iss "${payload.iss}"`);
  }
  if (!ALLOWED_EVENT_TYPES.has(payload.event_type)) {
    throw new Error(`bad event_type "${payload.event_type}"`);
  }
  if (expectedAudience) {
    const aud = payload.aud;
    const ok = Array.isArray(aud) ? aud.includes(expectedAudience) : aud === expectedAudience;
    if (!ok) throw new Error(`bad aud "${aud}"`);
  }
  return payload;
}

// === Domain logic =============================================================

/**
 * Decide the next custom-claims object for this user. Returns either:
 *   - the COMPLETE next claims map (Identity Platform replaces the whole map), or
 *   - `null` to indicate "no change".
 *
 * TODO: implement your policy here. Common patterns:
 *   - Set/unset a role claim based on an env-driven allow-list (e.g. process.env.ADMIN_EMAILS)
 *   - Enforce a tenant or organization invariant derived from userRecord.email's domain
 *   - Preserve claims you don't own — spread userRecord.customClaims and only touch your keys
 *
 * Guard against oversize payloads so a malformed policy doesn't block real users:
 *
 *   if (Buffer.byteLength(JSON.stringify(next), "utf8") > MAX_CUSTOM_CLAIMS_BYTES) {
 *     return null;
 *   }
 *
 * Parameters:
 *   userRecord.email        — string (may be empty)
 *   userRecord.customClaims — object (the user's current custom claims, may be {})
 */
function decideUserClaims(userRecord) {
  // No-op stub: never changes claims. Replace with your policy.
  return null;
}

/** Pluck `data.jwt` from the request body (object, JSON string, or Buffer). */
function readJwt(body) {
  let parsed = body;
  if (Buffer.isBuffer(parsed)) parsed = parsed.toString("utf8");
  if (typeof parsed === "string") {
    try { parsed = JSON.parse(parsed); } catch (_) { return null; }
  }
  if (parsed && parsed.data && typeof parsed.data.jwt === "string") {
    return parsed.data.jwt;
  }
  return null;
}

/** Pull `{ email, customClaims }` out of a verified JWT payload's `user_record`. */
function extractUserRecord(payload) {
  const userRecord = payload && payload.user_record;
  if (!userRecord) return null;
  let customClaims = userRecord.custom_claims;
  if (typeof customClaims === "string") {
    try { customClaims = JSON.parse(customClaims); }
    catch (_) { customClaims = {}; }
  }
  if (!customClaims || typeof customClaims !== "object") customClaims = {};
  return {
    email: typeof userRecord.email === "string" ? userRecord.email : "",
    customClaims,
  };
}

/**
 * Handler for both blocking triggers. ALWAYS responds HTTP 200 — a throw,
 * timeout or non-2xx would block the user (fail open: on any error, "no change").
 *   `{}`                                            -> no change
 *   `{ userRecord: { updateMask, customClaims } }`  -> persist these claims
 */
async function handleBlockingRequest(req, res) {
  try {
    const token = readJwt(req && req.body);
    if (!token) {
      res.status(200).json({});
      return;
    }

    // Prefer a configured, known-good audience (set at deploy time) so `aud`
    // is a real check. Fall back to the request Host header for defense-in-
    // depth only — on the open gateway it is attacker-controllable, so the
    // actual boundary remains the signature + `iss` checks (see
    // verifyAuthBlockingJwt). When neither is available the `aud` check is
    // skipped; the signature + `iss` still hold.
    const host = req && req.headers && req.headers.host;
    const expectedAudience =
      process.env.FUNCTION_URL || (host ? `https://${host}` : undefined);

    let payload;
    try {
      payload = await verifyAuthBlockingJwt(token, expectedAudience);
    } catch (err) {
      // Unverifiable JWT — could be a stray probe or a forgery attempt.
      // Never grant claims; fail open.
      console.warn(
        `identity-blocking: JWT verification failed (${err.message}); failing open`
      );
      res.status(200).json({});
      return;
    }

    const userRecord = extractUserRecord(payload);
    if (!userRecord) {
      res.status(200).json({});
      return;
    }

    const next = decideUserClaims(userRecord);
    if (next === null) {
      res.status(200).json({});
      return;
    }
    res
      .status(200)
      .json({ userRecord: { updateMask: "customClaims", customClaims: next } });
  } catch (err) {
    console.error("identity-blocking: failing open (no change)", err);
    try { res.status(200).json({}); } catch (_) { /* response already sent */ }
  }
}

// Entry points — deploy each with `gcloud functions deploy --entry-point=...`.
exports.beforeCreated = (req, res) => handleBlockingRequest(req, res);
exports.beforeSignedIn = (req, res) => handleBlockingRequest(req, res);

// Exposed for tests.
exports.decideUserClaims = decideUserClaims;
exports.verifyAuthBlockingJwt = verifyAuthBlockingJwt;
exports.readJwt = readJwt;
exports.extractUserRecord = extractUserRecord;
exports.handleBlockingRequest = handleBlockingRequest;

// Test hooks (do not use in production).
exports.__setJwksFetcherForTest = (fn) => {
  jwksFetcher = fn || defaultJwksFetcher;
};
exports.__resetJwksCacheForTest = () => {
  jwksKeys = new Map();
  lastJwksFetchAttemptMs = 0;
  jwksRefreshInFlight = null;
};
exports.__setProjectIdFetcherForTest = (fn) => {
  projectIdFetcher = fn || defaultProjectIdFromMetadata;
  projectIdPromise = null;
};
exports.__JWKS_FAILURE_BACKOFF_MS_FOR_TEST = JWKS_FAILURE_BACKOFF_MS;
