# Cloud Functions

Lightweight Google Cloud Functions deployed alongside the Swift backend via `gcloud` CLI. These functions bridge GCP services that cannot send events directly to Cloud Run.

**Why Cloud Functions?** Some Firebase / Identity Platform integrations can only be reached via Cloud Functions:

- **Firebase Auth lifecycle events** (`user.create` / `user.delete`) — only Cloud Functions v1 can receive them, and they need to be forwarded as [CloudEvents v1.0](https://cloudevents.io/) to the backend's webhook endpoint.
- **Firestore document events** (`accounts/{accountId}` created) — gen-1 Firestore triggers, forwarded as CloudEvents to the same webhook.
- **Identity Platform blocking triggers** (`beforeCreate` / `beforeSignIn`) — synchronous HTTP gates that can mutate the user's custom claims at sign-up / sign-in time. These run in-band and don't talk to the backend.

**No Firebase CLI required.** All functions are deployed via `gcloud functions deploy`. There is no `firebase.json`, no `firebase-functions` SDK, and no dependency on the Firebase CLI toolchain.

## Functions

<!-- AUTH_FORWARDER_BEGIN -->
### auth-forwarder

Forwards Firebase Auth user lifecycle events (creation, deletion) to the Swift backend running on Cloud Run.

| | |
|---|---|
| **Source** | [`auth-forwarder/`](auth-forwarder/) |
| **Runtime** | Node.js 20 |
| **Generation** | v1 (required — v2 does not support auth triggers) |
| **Dependencies** | None (zero `npm install` needed) |
| **Trigger** | Firebase Auth event (`providers/firebase.auth/eventTypes/user.create` / `user.delete`) |
| **Target** | `POST /` on the Cloud Run backend (`EventarcWebhookController`) |

#### How it works

```
Firebase Auth (user signs up / is deleted)
  │
  ▼
Cloud Function v1 (auth-forwarder)
  │  Receives raw UserRecord event
  │  Formats as CloudEvents v1.0 (ce-* headers + AuthEventData body)
  │  Authenticates via GCE metadata server ID token
  │
  ▼
Cloud Run (Swift backend)
  │  EventarcWebhookController receives POST /
  │  Parses CloudEvents headers + AuthEventData
  │  Dispatches UserCreatedIntegrationEvent / UserDeletedIntegrationEvent
  │
  ▼
CreateUserAccountCommandHandler / DeleteUserAccountCommandHandler
```

#### CloudEvents format

The function formats requests to match the backend's `EventarcWebhookController` expectations:

**Headers:**
| Header | Value |
|---|---|
| `Content-Type` | `application/json` |
| `ce-specversion` | `1.0` |
| `ce-type` | `google.firebase.auth.user.v1.created` or `google.firebase.auth.user.v1.deleted` |
| `ce-source` | `//firebase.googleapis.com/projects/{projectId}` |
| `ce-id` | The trigger's `context.eventId`, stable across redeliveries (the backend's inbox de-duplicates on `ce-source` + `ce-id`) |
| `ce-time` | The trigger's `context.timestamp` (ISO 8601) |
| `ce-subject` | `users/{uid}` |

**Body** (`AuthEventData`):
```json
{
  "uid": "abc123",
  "email": "user@example.com",
  "displayName": "Jane Doe",
  "photoUrl": null,
  "phoneNumber": null,
  "emailVerified": false,
  "disabled": false,
  "metadata": {
    "createTime": "2026-04-05T12:00:00.000Z"
  }
}
```

> **Field mappings:** Firebase uses `photoURL` (uppercase) → mapped to `photoUrl` (camelCase). Raw events use `metadata.createdAt` → mapped to `metadata.createTime`.

#### Environment variables

| Variable | Required | Description |
|---|---|---|
| `BACKEND_URL` | Yes | Full URL of the Cloud Run backend (e.g., `https://show-menu-backend-xxxxx.run.app`) |
| `GCP_PROJECT` | No | GCP project ID. Falls back to `GCLOUD_PROJECT` which is auto-set by the Cloud Functions runtime. |

#### Authentication

The function authenticates to Cloud Run using [GCP service-to-service authentication](https://cloud.google.com/run/docs/authenticating/service-to-service):

1. Fetches an ID token from the GCE metadata server with the backend URL as the audience
2. Sends it as `Authorization: Bearer <token>` header
3. Cloud Run validates the token and checks the caller's IAM permissions

The Cloud Function's service account must have `roles/run.invoker` on the Cloud Run service (see [IAM setup](#iam-setup) below).

Cloud Functions v1 uses the App Engine default service account: `<project-id>@appspot.gserviceaccount.com`.

> **Note:** `--no-gen2` is required in all deploy commands. Cloud Functions v2 does not support Firebase Auth triggers ([firebase/firebase-functions#1383](https://github.com/firebase/firebase-functions/issues/1383)).

#### Environments

Each deployed environment is a **separate GCP project** with its own Cloud Run service and its own pair of `onUserCreated` / `onUserDeleted` functions. A typical setup:

| Environment | GCP Project | Region | Cloud Run Service |
|---|---|---|---|
| **Production** | `show-menu-dev` | `europe-west1` | `show-menu-backend` |
| **Staging** | `show-menu-dev-staging` | `europe-west1` | `show-menu-backend` |

Add rows for additional environments (development, QA, etc.) as needed. The deploy and IAM steps below are run once per environment by changing the exported variables.

#### Deploy

Set the variables for the target environment, then deploy both functions from the repository root:

```bash
# Production
export PROJECT_ID=show-menu-dev
export REGION=europe-west1
export SERVICE_NAME=show-menu-backend

# Staging — uncomment for staging deploys
# export PROJECT_ID=show-menu-dev-staging
# export REGION=europe-west1
# export SERVICE_NAME=show-menu-backend

export BACKEND_URL=$(gcloud run services describe $SERVICE_NAME \
  --project=$PROJECT_ID \
  --region=$REGION \
  --format='value(status.url)')

gcloud functions deploy onUserCreated \
  --project=$PROJECT_ID \
  --no-gen2 \
  --entry-point onUserCreated \
  --trigger-event providers/firebase.auth/eventTypes/user.create \
  --trigger-resource $PROJECT_ID \
  --runtime nodejs20 \
  --region $REGION \
  --set-env-vars BACKEND_URL=$BACKEND_URL \
  --source ./cloud-functions/auth-forwarder

gcloud functions deploy onUserDeleted \
  --project=$PROJECT_ID \
  --no-gen2 \
  --entry-point onUserDeleted \
  --trigger-event providers/firebase.auth/eventTypes/user.delete \
  --trigger-resource $PROJECT_ID \
  --runtime nodejs20 \
  --region $REGION \
  --set-env-vars BACKEND_URL=$BACKEND_URL \
  --source ./cloud-functions/auth-forwarder
```

Re-export `PROJECT_ID` / `REGION` / `SERVICE_NAME` and re-run the block to deploy to each additional environment.

#### IAM setup

Grant the Cloud Function's service account permission to invoke the Cloud Run backend. Run this **once per environment** (re-exporting `PROJECT_ID`, `REGION`, and `SERVICE_NAME` between runs):

```bash
gcloud run services add-iam-policy-binding $SERVICE_NAME \
  --project=$PROJECT_ID \
  --member="serviceAccount:${PROJECT_ID}@appspot.gserviceaccount.com" \
  --role="roles/run.invoker" \
  --region=$REGION
```

#### Verify

After deployment, verify the end-to-end flow:

```bash
# 1. Check function status
gcloud functions describe onUserCreated \
  --project=$PROJECT_ID \
  --region=$REGION \
  --format='value(status)'

# 2. Create a test user via Firebase Console → Authentication → Add user

# 3. Check Cloud Function logs
gcloud functions logs read onUserCreated \
  --project=$PROJECT_ID \
  --region=$REGION \
  --limit=10

# 4. Check Cloud Run logs for the received webhook
gcloud logging read 'resource.type="cloud_run_revision" AND textPayload:"UserCreated"' \
  --project=$PROJECT_ID \
  --limit=5
```

#### Local development

For local development, point your client at the Firebase Auth emulator (`FIREBASE_AUTH_EMULATOR_HOST`) and forward auth events from the emulator directly to your locally running backend. The gcloud-deployed functions are for deployed environments only.
<!-- AUTH_FORWARDER_END -->

<!-- FIRESTORE_FORWARDER_BEGIN -->
### firestore-forwarder

Forwards the creation of `accounts/{accountId}` (a document the client writes) to the Swift backend, which links the account to its creator (`users/{uid}.accounts`) and grants the creator the `owner` permission (`accounts/{id}/permissions/{uid}`). Replaces Node's `onAccountCreated`.

| | |
|---|---|
| **Source** | [`firestore-forwarder/`](firestore-forwarder/) |
| **Runtime** | Node.js 20 |
| **Generation** | v1 (the trigger event format below is the gen-1 one) |
| **Dependencies** | None (zero `npm install` needed) |
| **Entry point** | `onAccountCreated` |
| **Trigger** | `providers/cloud.firestore/eventTypes/document.create` on `accounts/{accountId}` |
| **Target** | `POST /` on the Cloud Run backend (`EventarcWebhookController`) |
| **Tests** | `node --test` in the function directory (payload flattener + envelope) |

#### How it works

```
Client writes accounts/{accountId}
  │
  ▼
Cloud Function v1 (firestore-forwarder)
  │  Receives the raw event: value.fields = typed values (stringValue, timestampValue, …)
  │  Flattens the fields to plain JSON (Timestamps → ISO strings)
  │  Formats as CloudEvents v1.0, authenticates via GCE metadata server ID token
  │
  ▼
Cloud Run (Swift backend)
  │  EventarcWebhookController receives POST /
  │  Publishes AccountCreatedIntegrationEvent (id derived from ce-source + ce-id)
  │
  ▼
LinkAccountToCreatorCommandHandler          (IAM, inboxed)
GrantAccountOwnerPermissionCommandHandler   (Accounts, inboxed)
```

#### CloudEvents format

**Headers:**
| Header | Value |
|---|---|
| `Content-Type` | `application/json` |
| `ce-specversion` | `1.0` |
| `ce-type` | `google.cloud.firestore.document.v1.created` |
| `ce-source` | `//firestore.googleapis.com/projects/{projectId}/databases/(default)` |
| `ce-id` | The trigger's `context.eventId`, stable across redeliveries (the backend's inbox de-duplicates on `ce-source` + `ce-id`) |
| `ce-time` | The trigger's `context.timestamp` (ISO 8601) |
| `ce-subject` | `documents/accounts/{accountId}` |

**Body:**
```json
{
  "path": "accounts/acc-1",
  "documentId": "acc-1",
  "data": {
    "name": "Cafe",
    "creator": "uid-1",
    "createdAt": "2026-11-05T10:00:00.123Z"
  }
}
```

> **Field flattening:** a gen-1 trigger delivers typed values (`{"stringValue": "x"}`, `{"integerValue": "42"}` — a decimal *string*, `{"timestampValue": "…"}`, `mapValue.fields`, `arrayValue.values`, …). They are flattened to plain JSON: integers → numbers, timestamps → ISO strings (UTC, ms), references → the document path, maps/arrays recursively. The backend only reads `data.creator` and `data.name`.

#### Environment variables

| Variable | Required | Description |
|---|---|---|
| `BACKEND_URL` | Yes | Full URL of the Cloud Run backend (e.g., `https://show-menu-backend-xxxxx.run.app`) |
| `GCP_PROJECT` | No | GCP project ID. Falls back to `GCLOUD_PROJECT` which is auto-set by the Cloud Functions runtime. |

#### Authentication

Identical to [`auth-forwarder`](#auth-forwarder): an ID token from the GCE metadata server (audience = `BACKEND_URL`) sent as `Authorization: Bearer`. The backend verifies it with the same `EVENTARC_OIDC_AUDIENCE` / `EVENTARC_ALLOWED_SERVICE_ACCOUNTS`; the function's service account (`<project-id>@appspot.gserviceaccount.com`) needs `roles/run.invoker` on the Cloud Run service (the IAM setup of `auth-forwarder` covers it).

#### Delivery semantics

The function never throws on a backend failure (it logs the status), so gen-1 never redelivers; the backend's integration-event dispatcher also logs and swallows handler errors. The backend therefore makes the link robust instead of relying on retries: if the creator's `users/{uid}` document does not exist yet (the account event overtook the user-created one), it creates a minimal profile holding the link, which user onboarding later completes. A redelivery (same `ce-id`) is skipped by the inbox.

#### Deploy

Set the variables as for `auth-forwarder`, then from the repository root:

```bash
gcloud functions deploy onAccountCreated \
  --project=$PROJECT_ID \
  --no-gen2 \
  --entry-point onAccountCreated \
  --trigger-event providers/cloud.firestore/eventTypes/document.create \
  --trigger-resource "projects/$PROJECT_ID/databases/(default)/documents/accounts/{accountId}" \
  --runtime nodejs20 \
  --region $REGION \
  --set-env-vars BACKEND_URL=$BACKEND_URL \
  --source ./cloud-functions/firestore-forwarder
```

> **Region:** a gen-1 Firestore trigger must be deployed in the **same region as the Firestore database** (`show-menu-dev` uses multi-region `eur3`, whose function region is `europe-west1`).

#### Verify

```bash
# 1. Check function status
gcloud functions describe onAccountCreated --project=$PROJECT_ID --region=$REGION --format='value(status)'

# 2. Create a document in accounts/ (Firebase Console, or the client app)

# 3. Check the function logs
gcloud functions logs read onAccountCreated --project=$PROJECT_ID --region=$REGION --limit=10

# 4. Check the Cloud Run logs for the received webhook
gcloud logging read 'resource.type="cloud_run_revision" AND textPayload:"Account created"' \
  --project=$PROJECT_ID --limit=5
```

#### Local development

The emulator bridge `show-menu-firebase/forwarders` (`onAccountCreated`, a v1 `firestore.document("accounts/{accountId}").onCreate` trigger) sends the same envelope to `http://localhost:8080` without auth; it starts with `make emulators`.
<!-- FIRESTORE_FORWARDER_END -->

<!-- IDENTITY_BLOCKING_BEGIN -->
### identity-blocking

Stub Identity Platform blocking functions (`beforeCreate` / `beforeSignIn`) for setting custom claims on a user during sign-up and sign-in.

| | |
|---|---|
| **Source** | [`identity-blocking/`](identity-blocking/) — see [`identity-blocking/README.md`](identity-blocking/README.md) for deploy + register details |
| **Runtime** | Node.js 22 |
| **Generation** | v2 HTTP (`--gen2 --trigger-http`) — required for blocking functions |
| **Dependencies** | None (zero `npm install` needed — Node's built-in `crypto` + `https` for JWT verification) |
| **Entry points** | `beforeCreated`, `beforeSignedIn` |
| **Trigger** | Identity Platform blocking (synchronous HTTP, called by `identitytoolkit`) |
| **Auth** | `--allow-unauthenticated` at the gateway; function verifies the inbound body JWT signature itself (Identity Platform does not send `Authorization`) |
| **Output** | `{ userRecord: { updateMask: "customClaims", customClaims } }` or `{}` — always HTTP 200 (fail open) |

Out of the box the function is a **no-op stub**: it decodes the inbound Identity Platform JWT and returns HTTP 200 `{}` for every user. The policy decision lives in `decideUserClaims(userRecord)` near the top of [`identity-blocking/index.js`](identity-blocking/index.js) — fill it in with your own rule (allow-list → role claim, tenant invariant, domain check, etc.).

> **Prerequisite:** Firebase Auth must be **upgraded to Identity Platform** (GCIP) in the target GCP project — one-time, irreversible.
<!-- IDENTITY_BLOCKING_END -->

## Adding new functions

When adding a new Cloud Function:

1. Create a new subdirectory under `cloud-functions/` with `index.js` and `package.json`
2. Keep functions minimal — they should forward events, not contain business logic
3. Use the same service-to-service auth pattern (metadata server ID token)
4. Document the function in this README following the same format
5. Deploy via `gcloud functions deploy`
