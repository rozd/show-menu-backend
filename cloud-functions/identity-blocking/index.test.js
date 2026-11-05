"use strict";

// Unit tests for the security-critical JWT verification and fail-open wire
// handling in index.js. Zero dependencies — Node's built-in `node:test`,
// `node:assert`, and `node:crypto` (consistent with the function's zero-dep
// policy). Run with: `node --test` from this directory.

const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");

const fn = require("./index.js");

// === Test fixtures ============================================================

const PROJECT_ID = "demo-project";
const KID = "test-kid-1";
const AUDIENCE = "https://identity-beforeSignedIn-abc.run.app";

// One RSA keypair stands in for Google's securetoken@system signing key.
const { publicKey, privateKey } = crypto.generateKeyPairSync("rsa", {
  modulusLength: 2048,
});

// A second, unrelated keypair to simulate a key that is NOT in the JWKS.
const other = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });

/** JWKS document as returned by Google's endpoint (one signing key). */
function jwksDoc(kid = KID, key = publicKey) {
  const jwk = key.export({ format: "jwk" });
  jwk.kid = kid;
  jwk.alg = "RS256";
  jwk.use = "sig";
  return { keys: [jwk] };
}

function b64url(obj) {
  return Buffer.from(JSON.stringify(obj), "utf8").toString("base64url");
}

/**
 * Build a JWT. `opts` overrides header/payload fields and the signing key/alg.
 */
function makeJwt(opts = {}) {
  const now = Math.floor(Date.now() / 1000);
  // `header: ...` REPLACES the default header outright (so a test can omit
  // `kid`); only fall back to the default when no header override is given.
  const header = opts.header || { alg: "RS256", kid: KID, typ: "JWT" };
  const payload = Object.assign(
    {
      iss: `https://securetoken.google.com/${PROJECT_ID}`,
      aud: AUDIENCE,
      event_type: "beforeSignIn",
      iat: now,
      exp: now + 3600,
      user_record: { email: "user@example.com", custom_claims: {} },
    },
    opts.payload
  );
  const headerB64 = b64url(header);
  const payloadB64 = b64url(payload);
  const signingInput = Buffer.from(`${headerB64}.${payloadB64}`, "utf8");

  if (opts.unsigned) {
    return `${headerB64}.${payloadB64}.`;
  }
  if (opts.rawSignature !== undefined) {
    return `${headerB64}.${payloadB64}.${opts.rawSignature}`;
  }
  const signKey = opts.signKey || privateKey;
  const sig = crypto.sign("RSA-SHA256", signingInput, signKey).toString("base64url");
  return `${headerB64}.${payloadB64}.${sig}`;
}

/** Install a JWKS fetcher + project ID + reset cache for an isolated test. */
function setup(jwks = jwksDoc()) {
  fn.__setJwksFetcherForTest(async () => jwks);
  fn.__setProjectIdFetcherForTest(async () => PROJECT_ID);
  fn.__resetJwksCacheForTest();
}

function teardown() {
  fn.__setJwksFetcherForTest(null);
  fn.__setProjectIdFetcherForTest(null);
  fn.__resetJwksCacheForTest();
}

// === verifyAuthBlockingJwt: happy path ========================================

test("verifies a valid token and returns the payload", async () => {
  setup();
  const payload = await fn.verifyAuthBlockingJwt(makeJwt(), AUDIENCE);
  assert.equal(payload.event_type, "beforeSignIn");
  assert.equal(payload.user_record.email, "user@example.com");
  teardown();
});

test("accepts beforeCreate event_type", async () => {
  setup();
  const payload = await fn.verifyAuthBlockingJwt(
    makeJwt({ payload: { event_type: "beforeCreate" } }),
    AUDIENCE
  );
  assert.equal(payload.event_type, "beforeCreate");
  teardown();
});

// === Algorithm enforcement ====================================================

test("rejects alg=none", async () => {
  setup();
  await assert.rejects(
    () => fn.verifyAuthBlockingJwt(makeJwt({ header: { alg: "none" }, unsigned: true }), AUDIENCE),
    /unsupported alg/
  );
  teardown();
});

test("rejects HS256 (algorithm confusion attempt)", async () => {
  setup();
  // Forge an HS256 token using the PUBLIC key as the HMAC secret — the classic
  // RS/HS confusion attack. Must be rejected at the alg gate.
  const now = Math.floor(Date.now() / 1000);
  const header = b64url({ alg: "HS256", kid: KID, typ: "JWT" });
  const payload = b64url({
    iss: `https://securetoken.google.com/${PROJECT_ID}`,
    aud: AUDIENCE,
    event_type: "beforeSignIn",
    iat: now,
    exp: now + 3600,
  });
  const pubPem = publicKey.export({ type: "spki", format: "pem" });
  const sig = crypto
    .createHmac("sha256", pubPem)
    .update(`${header}.${payload}`)
    .digest("base64url");
  await assert.rejects(
    () => fn.verifyAuthBlockingJwt(`${header}.${payload}.${sig}`, AUDIENCE),
    /unsupported alg/
  );
  teardown();
});

// === kid handling =============================================================

test("rejects a token with no kid", async () => {
  setup();
  await assert.rejects(
    () => fn.verifyAuthBlockingJwt(makeJwt({ header: { alg: "RS256", typ: "JWT" } }), AUDIENCE),
    /missing kid/
  );
  teardown();
});

test("rejects an unknown kid (no matching JWKS key)", async () => {
  setup();
  await assert.rejects(
    () => fn.verifyAuthBlockingJwt(makeJwt({ header: { alg: "RS256", kid: "nope", typ: "JWT" } }), AUDIENCE),
    /no JWKS key for kid/
  );
  teardown();
});

// === Signature verification ===================================================

test("rejects a tampered payload (signature mismatch)", async () => {
  setup();
  const jwt = makeJwt();
  const parts = jwt.split(".");
  // Swap in a different payload while keeping the original signature.
  const tampered = b64url({
    iss: `https://securetoken.google.com/${PROJECT_ID}`,
    aud: AUDIENCE,
    event_type: "beforeSignIn",
    iat: Math.floor(Date.now() / 1000),
    exp: Math.floor(Date.now() / 1000) + 3600,
    user_record: { email: "attacker@evil.com" },
  });
  await assert.rejects(
    () => fn.verifyAuthBlockingJwt(`${parts[0]}.${tampered}.${parts[2]}`, AUDIENCE),
    /invalid signature/
  );
  teardown();
});

test("rejects a token signed by a key not in the JWKS", async () => {
  setup();
  await assert.rejects(
    () => fn.verifyAuthBlockingJwt(makeJwt({ signKey: other.privateKey }), AUDIENCE),
    /invalid signature/
  );
  teardown();
});

test("rejects garbage in the signature segment", async () => {
  setup();
  await assert.rejects(
    () => fn.verifyAuthBlockingJwt(makeJwt({ rawSignature: "!!!not-base64!!!" }), AUDIENCE),
    /invalid signature/
  );
  teardown();
});

// === Claim checks: exp / iat ==================================================

test("rejects an expired token beyond skew", async () => {
  setup();
  const now = Math.floor(Date.now() / 1000);
  await assert.rejects(
    () => fn.verifyAuthBlockingJwt(makeJwt({ payload: { exp: now - 120, iat: now - 3720 } }), AUDIENCE),
    /token expired/
  );
  teardown();
});

test("accepts a token expired only within skew", async () => {
  setup();
  const now = Math.floor(Date.now() / 1000);
  // exp 30s in the past, within the 60s skew window → still accepted.
  const payload = await fn.verifyAuthBlockingJwt(
    makeJwt({ payload: { exp: now - 30 } }),
    AUDIENCE
  );
  assert.equal(payload.event_type, "beforeSignIn");
  teardown();
});

test("rejects a token issued in the future beyond skew", async () => {
  setup();
  const now = Math.floor(Date.now() / 1000);
  await assert.rejects(
    () => fn.verifyAuthBlockingJwt(makeJwt({ payload: { iat: now + 120 } }), AUDIENCE),
    /token issued in future/
  );
  teardown();
});

// === Claim checks: iss / event_type / aud =====================================

test("rejects a bad iss (wrong project)", async () => {
  setup();
  await assert.rejects(
    () =>
      fn.verifyAuthBlockingJwt(
        makeJwt({ payload: { iss: "https://securetoken.google.com/other-project" } }),
        AUDIENCE
      ),
    /bad iss/
  );
  teardown();
});

test("rejects a bad event_type", async () => {
  setup();
  await assert.rejects(
    () => fn.verifyAuthBlockingJwt(makeJwt({ payload: { event_type: "afterSignIn" } }), AUDIENCE),
    /bad event_type/
  );
  teardown();
});

test("rejects a missing event_type", async () => {
  setup();
  await assert.rejects(
    () => fn.verifyAuthBlockingJwt(makeJwt({ payload: { event_type: undefined } }), AUDIENCE),
    /bad event_type/
  );
  teardown();
});

test("rejects an aud mismatch when an audience is expected", async () => {
  setup();
  await assert.rejects(
    () => fn.verifyAuthBlockingJwt(makeJwt({ payload: { aud: "https://evil.example" } }), AUDIENCE),
    /bad aud/
  );
  teardown();
});

test("accepts an aud array containing the expected audience", async () => {
  setup();
  const payload = await fn.verifyAuthBlockingJwt(
    makeJwt({ payload: { aud: ["https://other", AUDIENCE] } }),
    AUDIENCE
  );
  assert.equal(payload.event_type, "beforeSignIn");
  teardown();
});

test("skips the aud check when no expectedAudience is provided (missing Host)", async () => {
  setup();
  // Token's aud is anything; with no expectedAudience the check is skipped and
  // the signature + iss still hold.
  const payload = await fn.verifyAuthBlockingJwt(
    makeJwt({ payload: { aud: "https://whatever" } }),
    undefined
  );
  assert.equal(payload.event_type, "beforeSignIn");
  teardown();
});

// === Malformed JWT shapes =====================================================

test("rejects a JWT with the wrong number of segments", async () => {
  setup();
  await assert.rejects(() => fn.verifyAuthBlockingJwt("a.b", AUDIENCE), /malformed JWT/);
  await assert.rejects(() => fn.verifyAuthBlockingJwt("a.b.c.d", AUDIENCE), /malformed JWT/);
  teardown();
});

test("rejects a JWT whose header is not valid JSON", async () => {
  setup();
  const bad = `${Buffer.from("not json", "utf8").toString("base64url")}.${b64url({})}.sig`;
  await assert.rejects(() => fn.verifyAuthBlockingJwt(bad, AUDIENCE));
  teardown();
});

// === readJwt ==================================================================

test("readJwt extracts data.jwt from an object body", () => {
  assert.equal(fn.readJwt({ data: { jwt: "x.y.z" } }), "x.y.z");
});

test("readJwt extracts data.jwt from a JSON string body", () => {
  assert.equal(fn.readJwt(JSON.stringify({ data: { jwt: "x.y.z" } })), "x.y.z");
});

test("readJwt extracts data.jwt from a Buffer body", () => {
  assert.equal(fn.readJwt(Buffer.from(JSON.stringify({ data: { jwt: "x.y.z" } }))), "x.y.z");
});

test("readJwt returns null for garbage / missing jwt", () => {
  assert.equal(fn.readJwt("not json"), null);
  assert.equal(fn.readJwt({}), null);
  assert.equal(fn.readJwt({ data: {} }), null);
  assert.equal(fn.readJwt({ data: { jwt: 123 } }), null);
  assert.equal(fn.readJwt(null), null);
  assert.equal(fn.readJwt(undefined), null);
});

// === extractUserRecord ========================================================

test("extractUserRecord parses object and string custom_claims", () => {
  assert.deepEqual(
    fn.extractUserRecord({ user_record: { email: "a@b.com", custom_claims: { role: "x" } } }),
    { email: "a@b.com", emailVerified: false, customClaims: { role: "x" } }
  );
  assert.deepEqual(
    fn.extractUserRecord({ user_record: { email: "a@b.com", custom_claims: '{"role":"y"}' } }),
    { email: "a@b.com", emailVerified: false, customClaims: { role: "y" } }
  );
});

test("extractUserRecord defaults invalid/missing fields", () => {
  assert.deepEqual(fn.extractUserRecord({ user_record: {} }), { email: "", emailVerified: false, customClaims: {} });
  assert.deepEqual(
    fn.extractUserRecord({ user_record: { email: 5, custom_claims: "not json" } }),
    { email: "", emailVerified: false, customClaims: {} }
  );
  assert.equal(fn.extractUserRecord({}), null);
  assert.equal(fn.extractUserRecord(null), null);
});

// === handleBlockingRequest: fail-open contract ================================

function fakeRes() {
  return {
    _status: undefined,
    _body: undefined,
    status(s) { this._status = s; return this; },
    json(b) { this._body = b; return this; },
  };
}

test("handleBlockingRequest returns 200 {} with no JWT (short-circuit)", async () => {
  const res = fakeRes();
  await fn.handleBlockingRequest({ body: "{}", headers: {} }, res);
  assert.equal(res._status, 200);
  assert.deepEqual(res._body, {});
});

test("handleBlockingRequest fails open (200 {}) on an unverifiable JWT", async () => {
  setup();
  const res = fakeRes();
  // Token signed by an unrelated key → verification fails → fail open.
  await fn.handleBlockingRequest(
    { body: { data: { jwt: makeJwt({ signKey: other.privateKey }) } }, headers: { host: "h" } },
    res
  );
  assert.equal(res._status, 200);
  assert.deepEqual(res._body, {});
  teardown();
});

test("handleBlockingRequest returns 200 {} for a valid token whose user is not an admin", async () => {
  setup();
  process.env.FUNCTION_URL = AUDIENCE;
  const res = fakeRes();
  await fn.handleBlockingRequest(
    { body: { data: { jwt: makeJwt() } }, headers: { host: "ignored" } },
    res
  );
  assert.equal(res._status, 200);
  // Not allow-listed → no change.
  assert.deepEqual(res._body, {});
  delete process.env.FUNCTION_URL;
  teardown();
});

// === F1 regression: transient JWKS failure must NOT poison for the full 30s ===

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

test("a transient JWKS fetch failure does not poison verification (F1)", async () => {
  fn.__setProjectIdFetcherForTest(async () => PROJECT_ID);
  fn.__resetJwksCacheForTest();

  let calls = 0;
  fn.__setJwksFetcherForTest(async () => {
    calls += 1;
    if (calls === 1) throw new Error("transient network error");
    return jwksDoc();
  });

  // First verification: fetch fails → fail (caller fails open).
  await assert.rejects(() => fn.verifyAuthBlockingJwt(makeJwt(), AUDIENCE), /no JWKS key/);
  assert.equal(calls, 1);

  // Wait out the SHORT failure backoff (a few seconds) — NOT the full 30s
  // success interval. Under the old (buggy) code the throttle timestamp was
  // advanced on the failed attempt the same as a success, so verification
  // stayed broken for ~30s. With the fix, recovery happens within the short
  // backoff window: refetch succeeds and the token verifies.
  await delay(fn.__JWKS_FAILURE_BACKOFF_MS_FOR_TEST + 50);
  const payload = await fn.verifyAuthBlockingJwt(makeJwt(), AUDIENCE);
  assert.equal(payload.event_type, "beforeSignIn");
  assert.equal(calls, 2, "expected a prompt retry after the short failure backoff");

  teardown();
});

test("a failed JWKS fetch is throttled within the short backoff window (bounds probes)", async () => {
  fn.__setProjectIdFetcherForTest(async () => PROJECT_ID);
  fn.__resetJwksCacheForTest();

  let calls = 0;
  fn.__setJwksFetcherForTest(async () => {
    calls += 1;
    throw new Error("still down");
  });

  await assert.rejects(() => fn.verifyAuthBlockingJwt(makeJwt(), AUDIENCE), /no JWKS key/);
  // Immediate retry within the backoff window must NOT trigger another fetch.
  await assert.rejects(() => fn.verifyAuthBlockingJwt(makeJwt(), AUDIENCE), /no JWKS key/);
  assert.equal(calls, 1, "a second fetch within the backoff window should be throttled");

  teardown();
});

test("successful JWKS fetch is cached and not refetched within the throttle window", async () => {
  fn.__setProjectIdFetcherForTest(async () => PROJECT_ID);
  fn.__resetJwksCacheForTest();

  let calls = 0;
  fn.__setJwksFetcherForTest(async () => {
    calls += 1;
    return jwksDoc();
  });

  await fn.verifyAuthBlockingJwt(makeJwt(), AUDIENCE);
  await fn.verifyAuthBlockingJwt(makeJwt(), AUDIENCE);
  assert.equal(calls, 1, "JWKS should be fetched once and served from cache");

  teardown();
});

// === decideUserClaims: ADMIN_EMAILS policy ====================================

function withAdminEmails(value, fnBody) {
  const prev = process.env.ADMIN_EMAILS;
  if (value === undefined) delete process.env.ADMIN_EMAILS; else process.env.ADMIN_EMAILS = value;
  try { return fnBody(); } finally {
    if (prev === undefined) delete process.env.ADMIN_EMAILS; else process.env.ADMIN_EMAILS = prev;
  }
}

test("decideUserClaims grants admin to a verified allow-listed email (case/space-insensitive)", () => {
  withAdminEmails(" Boss@Example.com , other@x.io ", () => {
    assert.deepEqual(
      fn.decideUserClaims({ email: "boss@example.com", emailVerified: true, customClaims: { tier: "gold" } }),
      { tier: "gold", admin: true }
    );
  });
});

test("decideUserClaims does nothing for an unverified allow-listed email", () => {
  withAdminEmails("boss@example.com", () => {
    assert.equal(fn.decideUserClaims({ email: "boss@example.com", emailVerified: false, customClaims: {} }), null);
  });
});

test("decideUserClaims does nothing for a non-allow-listed, empty-email or already-admin user", () => {
  withAdminEmails("boss@example.com", () => {
    assert.equal(fn.decideUserClaims({ email: "u@example.com", emailVerified: true, customClaims: {} }), null);
    assert.equal(fn.decideUserClaims({ email: "", emailVerified: true, customClaims: {} }), null);
    assert.equal(
      fn.decideUserClaims({ email: "boss@example.com", emailVerified: true, customClaims: { admin: true } }),
      null
    );
  });
});

test("decideUserClaims does nothing when ADMIN_EMAILS is unset or blank", () => {
  withAdminEmails(undefined, () => {
    assert.equal(fn.decideUserClaims({ email: "a@b.com", emailVerified: true, customClaims: {} }), null);
  });
  withAdminEmails(" , ", () => {
    assert.equal(fn.decideUserClaims({ email: "", emailVerified: true, customClaims: {} }), null);
  });
});

test("handleBlockingRequest returns the admin claim for an allow-listed verified user", async () => {
  setup();
  process.env.FUNCTION_URL = AUDIENCE;
  process.env.ADMIN_EMAILS = "boss@example.com";
  const res = fakeRes();
  await fn.handleBlockingRequest(
    {
      body: { data: { jwt: makeJwt({ payload: { user_record: { email: "boss@example.com", email_verified: true, custom_claims: {} } } }) } },
      headers: { host: "ignored" },
    },
    res
  );
  assert.equal(res._status, 200);
  assert.deepEqual(res._body, { userRecord: { updateMask: "customClaims", customClaims: { admin: true } } });
  delete process.env.FUNCTION_URL;
  delete process.env.ADMIN_EMAILS;
  teardown();
});
