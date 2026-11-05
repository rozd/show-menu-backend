# identity-blocking

GCP Identity Platform blocking functions (`beforeCreate` / `beforeSignIn`) — a deployable stub for setting custom claims on a user during sign-up and sign-in. Zero-dependency, deployed via `gcloud functions deploy` (no Firebase CLI).

The policy decision is a TODO at `decideUserClaims(userRecord)` in [`index.js`](index.js). Out of the box the function is a no-op: it decodes the inbound JWT and responds HTTP 200 `{}` for every user. Fill in `decideUserClaims` with your rule (allow-list → role claim, tenant invariant, domain check, etc.).

## At a glance

| | |
|---|---|
| **Source** | [`index.js`](index.js) |
| **Runtime** | Node.js 22 |
| **Generation** | v2 HTTP (`--gen2 --trigger-http`) — required for blocking functions |
| **Dependencies** | None (zero `npm install` needed — uses Node's built-in `crypto` + `https` for JWT verification) |
| **Entry points** | `beforeCreated`, `beforeSignedIn` — raw `(req, res)` handlers; deploy each as its own function with `--entry-point=...` |
| **Trigger** | Identity Platform blocking: `beforeCreate` / `beforeSignIn` (HTTP, called by the `identitytoolkit` service) |
| **Auth** | `--allow-unauthenticated` at the gateway; function verifies the inbound body JWT signature (`securetoken@system` JWKS) — Identity Platform does **not** send an `Authorization` header. See **Wire format & trust** below. |
| **Output** | `{ userRecord: { updateMask: "customClaims", customClaims } }` to set claims, else `{}` — always HTTP 200 (fails open; never blocks a user) |

## How it works

```
User signs up / signs in
  │
  ▼
beforeCreate  (sync, before the account exists)
beforeSignIn  (sync, on every sign-in — reconciles on each attempt)
  │  decodes inbound JWT → { email, customClaims }
  │  calls decideUserClaims(userRecord)
  │   ├─ returns null              → 200 {}                                          (no change)
  │   └─ returns claims object     → 200 { userRecord: { updateMask:"customClaims", customClaims } }
  │  ANY error / malformed input   → 200 {}, log                                     (FAIL OPEN)
  ▼
Identity Platform persists the returned customClaims onto the user record
```

`beforeCreate` runs once at account creation; `beforeSignIn` runs on every sign-in (so policy changes — e.g. a new entry in an allow-list — take effect on the user's next sign-in without redeploying).

**Wire format & trust** — there is no `firebase-functions` SDK wrapping this, so the shapes are handled directly:

- **Request:** `POST` with JSON body `{ "data": { "jwt": "<header>.<payload>.<sig>" } }`. The JWT payload carries `user_record` in snake_case (`email`, `custom_claims`, …) plus `event_type` (`beforeCreate` / `beforeSignIn`).
- **Response:** HTTP `200` with `{ "userRecord": { "updateMask": "customClaims", "customClaims": { … } } }` to persist claims, or `{}` for no change. A non-2xx (or a throw, or a timeout) would **block** the user — hence "fail open": every path returns `200`.
- **Trust:** the inbound JWT signature **is verified in code** — Identity Platform calls blocking functions *without* an `Authorization` header (only the body JWT), so IAM cannot be the gate; the Cloud Run service deploys `--allow-unauthenticated` and the function rejects unverifiable calls itself. **The actual trust boundary is the `RS256` signature over Google's `securetoken@system` JWKS plus `iss` == this project** — neither can be forged without a Google-signed token for this exact project. Checks: `alg=RS256` against Google's `securetoken@system` JWKS by `kid`; `iss=https://securetoken.google.com/<project>` where `<project>` is the resolved project ID (env var `GOOGLE_CLOUD_PROJECT` / `GCLOUD_PROJECT`, else the GCE metadata server — see the Environment variables table); `event_type ∈ {beforeCreate, beforeSignIn}`; `exp/iat` within 60s skew. The `aud` check is **best-effort defense-in-depth only**, not a boundary: by default it is derived from the request `Host` header (`https://<host>`), which a direct caller on the open gateway fully controls, so do not rely on it. Set `FUNCTION_URL` at deploy time to pin `aud` to a known-good, non-attacker-controlled value (recommended); if neither `FUNCTION_URL` nor a `Host` header is present the `aud` check is skipped and the signature + `iss` still hold. Zero npm deps — uses Node's built-in `crypto` + `https`. JWKS is fetched lazily on first miss, cached in-process, fetched under a strict timeout (~1.5s) so a stalled endpoint can never hang past the blocking-function deadline (which would fail *closed* and block the user), and refresh is throttled to once per 30s on success — a *failed* fetch only backs off a couple of seconds so a transient error never poisons verification for the full 30s window.
- **Size limit:** Identity Platform rejects custom-claims payloads serializing to more than `MAX_CUSTOM_CLAIMS_BYTES` (1000 bytes). The stub `decideUserClaims` returns `null` so this never applies; once you implement policy, guard against oversize with `Buffer.byteLength(JSON.stringify(next), "utf8")`.

## Configuration

### Environment variables

| Variable | Required | Description |
|---|---|---|
| `GOOGLE_CLOUD_PROJECT` (or legacy `GCLOUD_PROJECT`) | No | GCP project ID used to build the expected JWT `iss` (`https://securetoken.google.com/<project>`). **Cloud Functions gen-2 / Cloud Run do not set this automatically** (unlike App Engine or gen-1) — when both env vars are absent, the function falls back to the GCE metadata server (`metadata.google.internal/computeMetadata/v1/project/project-id`) and memoizes the result. Set this env var manually only if you run the function outside Google Cloud (e.g. self-hosted tests) or want to override auto-detection. |
| `FUNCTION_URL` | No (recommended) | The function's own deployed URL (e.g. `https://identity-beforesignedin-xxxxx.run.app`), used as the expected JWT `aud`. When set, `aud` becomes a real, non-attacker-controlled defense-in-depth check. When **unset**, the function falls back to deriving `aud` from the request `Host` header — which a direct caller on the open gateway controls, so it provides no protection (the signature + `iss` checks remain the actual boundary either way). Set it after the first deploy once the stable gen-2 URI is known (see the **Register** step, which already captures it). |

The stub takes no policy-specific env vars. When you implement `decideUserClaims`, add policy inputs (allow-lists, feature flags, etc.) and set them at deploy time with `--set-env-vars=...`.

> **`gcloud` and comma-valued env vars.** `gcloud` dict flags (`--set-env-vars`, `--update-env-vars`) use `,` as the pair separator, so a comma-containing value like `a@x.com,b@y.com` is misread as two pairs (`Bad syntax for dict arg: [b@y.com]`). The `^DELIM^` prefix (see `gcloud topic escaping`) reassigns the separator: `--set-env-vars="^|^MY_LIST=a@x.com,b@y.com"`. Equivalent alternative: `--env-vars-file=env.yaml`.

## Prerequisites

Firebase Auth must be **upgraded to Identity Platform** (the productized tier of Firebase Auth, a.k.a. GCIP) — **one-time, irreversible** per GCP project; you cannot downgrade. Firebase Console → **Authentication → Settings → "Upgrade to Identity Platform"** (no clean `gcloud` equivalent). Do staging first, validate, then production.

## Deploy

Deploy both functions as gen-2 HTTP functions from the repository root:

```bash
# Production
export PROJECT_ID=show-menu-dev
export REGION=us-central1

# Staging — uncomment for staging deploys
# export PROJECT_ID=show-menu-dev-staging
# export REGION=us-central1

for fn in beforeCreated beforeSignedIn; do
  gcloud functions deploy "identity-$fn" \
    --project="$PROJECT_ID" --gen2 --runtime=nodejs22 --region="$REGION" \
    --trigger-http --allow-unauthenticated --entry-point="$fn" \
    --source=./cloud-functions/identity-blocking
done
```

Re-export `PROJECT_ID` / `REGION` and re-run the block to deploy to each additional environment.

> **Why `--allow-unauthenticated`.** Identity Platform calls blocking functions **without** an `Authorization` header (only the body JWT — confirmed by `firebase-functions` source and by `Empty Authorization header value` Cloud Run logs from `User-Agent: Google-Firebase`). IAM therefore cannot gate the call: with `--no-allow-unauthenticated` the GFE rejects every Identity Platform request *before* it reaches the service, and the client surfaces the GFE HTML page *"Your client does not have permission to get URL `/` from this server"*. The function instead verifies the body JWT signature itself (see **Wire format & trust** above), so the gateway must be open. No `roles/run.invoker` binding is needed.

## Register with Identity Platform

After deploy, register the blocking-function trigger URIs on the Identity Platform config (one-time per project; gen-2 URIs are stable):

```bash
BC=$(gcloud functions describe identity-beforeCreated  --project="$PROJECT_ID" --region="$REGION" --gen2 --format='value(serviceConfig.uri)')
BS=$(gcloud functions describe identity-beforeSignedIn --project="$PROJECT_ID" --region="$REGION" --gen2 --format='value(serviceConfig.uri)')
curl -X PATCH \
  "https://identitytoolkit.googleapis.com/admin/v2/projects/$PROJECT_ID/config?updateMask=blockingFunctions" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "x-goog-user-project: $PROJECT_ID" \
  -H "Content-Type: application/json" \
  -d "{\"blockingFunctions\":{\"triggers\":{\"beforeCreate\":{\"functionUri\":\"$BC\"},\"beforeSignIn\":{\"functionUri\":\"$BS\"}}}}"
```

> **`x-goog-user-project` is required**, not optional. `gcloud auth print-access-token` mints a *user* token from your login, which has no implicit billing/quota project — `identitytoolkit.googleapis.com` then 403s with `"requires a quota project, which is not set by default"` and `consumer: "projects/32555940559"` (the public gcloud SDK fallback project). The header tells the API which project to bill quota against. Persistent alternative: `gcloud auth application-default set-quota-project "$PROJECT_ID"` once, then drop the header.

> **(Recommended) Pin the `aud` check.** The gen-2 URIs above (`$BC` / `$BS`) are stable, so set each function's own URL as `FUNCTION_URL` to make the `aud` check a real defense-in-depth boundary instead of the attacker-controllable `Host` fallback (see **Wire format & trust**):
> ```bash
> gcloud functions deploy identity-beforeCreated  --project="$PROJECT_ID" --region="$REGION" --gen2 --update-env-vars="FUNCTION_URL=$BC"
> gcloud functions deploy identity-beforeSignedIn --project="$PROJECT_ID" --region="$REGION" --gen2 --update-env-vars="FUNCTION_URL=$BS"
> ```

## Verify

```bash
gcloud functions describe identity-beforeSignedIn --project="$PROJECT_ID" --region="$REGION" --gen2 --format='value(state)'

curl -sS "https://identitytoolkit.googleapis.com/admin/v2/projects/$PROJECT_ID/config" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "x-goog-user-project: $PROJECT_ID" | grep -A6 blockingFunctions

gcloud functions logs read identity-beforeSignedIn --project="$PROJECT_ID" --region="$REGION" --gen2 --limit=20
```

With the stub deployed, signing up / signing in should leave the user record's `customAttributes` untouched. Once you implement `decideUserClaims`, sign in with a user whose policy should apply and confirm the expected claim appears. The Firebase Console does **not** display custom claims (only the Auth emulator UI does) — inspect the user record via the Identity Toolkit admin API:

```bash
curl -sS -X POST \
  "https://identitytoolkit.googleapis.com/v1/projects/$PROJECT_ID/accounts:lookup" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "x-goog-user-project: $PROJECT_ID" \
  -H "Content-Type: application/json" \
  -d '{"email":["user@example.com"]}'
# → users[0].customAttributes carries the claims as a JSON string
```

(or `firebase auth:export users.json --project "$PROJECT_ID"`, which includes `customAttributes`; or `getIdTokenResult()` in the app).

> **Console UI gotcha — "None" in the Triggers dropdown is cosmetic.** The Identity Platform → **Settings → Triggers** page lists only **gen-1** Cloud Functions in its dropdown; gen-2 functions are Cloud Run services (URI host `*.run.app`, not `*.cloudfunctions.net`) and aren't enumerated. So even when `blockingFunctions.triggers.*.functionUri` is correctly set, the dropdown renders "None". Trust the `GET …/config` response (the field above) and the function logs, not the console.

## Tests

The security-critical verification path has a zero-dependency unit suite in [`index.test.js`](index.test.js) built on Node's built-in `node:test` + `node:crypto` (no `npm install`). It generates an RSA keypair to stand in for Google's `securetoken@system` signing key and exercises: the valid-token happy path, algorithm enforcement (`none` / `HS256` RS-confusion both rejected), missing/unknown `kid`, tampered-payload and wrong-key signature failures, `exp`/`iat` skew boundaries, bad `iss`/`event_type`, `aud` match/mismatch/array/missing-Host, malformed JWT shapes, `readJwt` / `extractUserRecord` edge cases, the `handleBlockingRequest` fail-open contract, and the JWKS transient-failure behavior (a failed fetch must not poison verification for the full 30s window) using the `__set*ForTest` hooks.

```bash
node --test cloud-functions/identity-blocking
# or, from this directory:
npm test
```

## Local development

The Firebase emulator does **not** run these — a raw `gcloud`-style HTTP function isn't discovered as a blocking function by the Auth/Functions emulators (that requires the `firebase-functions` SDK). For local testing of custom-claims-dependent flows, set claims manually via the Auth emulator UI or `admin.auth().setCustomUserClaims(uid, { ... })`.

You can still smoke-test the handler in isolation. With no JWT in the body it short-circuits to `{}` without invoking JWT verification (so no metadata-server or JWKS calls needed locally):

```bash
node -e "
  (async () => {
    const { handleBlockingRequest } = require('./index.js');
    const req = { body: '{}', headers: {} };
    const res = {
      status(s) { this._s = s; return this; },
      json(b)   { console.log(JSON.stringify({status: this._s, body: b})); }
    };
    await handleBlockingRequest(req, res);
  })();
"
# → {"status":200,"body":{}}
```
