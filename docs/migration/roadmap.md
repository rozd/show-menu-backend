# show-menu: Firebase Cloud Functions → Vapor (Cloud Run) migration roadmap

_Created 2026-11-05. Source: `../show-menu-firebase/functions` (Node 20, firebase-functions v5). Target: this repo (`ShowMenuBackend`, Swift 6.2, Vapor, DDD/CQRS template)._

## 0. How to use this roadmap
- **One step = one session = one branch** (`migration/S07-users-onboarding`, …). Steps are ordered by dependency. Do not start a step until its **Depends on** list is merged.
- Every step has a **session brief**: goal, scope (files and repos), out of scope, references to port from, and a **done** check. Paste the brief as the opening prompt of the session.
- **The parity oracle** is `../show-menu-firebase/test-harness`, a black-box suite that has a ready-made `npm run test:vapor:local` target (`TARGET_API_URL=http://127.0.0.1:8080/api/v1`). Most "done" checks are "harness file X is green". Swift unit tests (Swift Testing, `makeSUT()` + in-memory doubles) are required in every step as well.
- **Multi-repo gates.** Some steps edit sibling repos (`show-menu-firebase`, `show-menu-flutter`). Name those targets in your first message of the session, so that sidekick handoffs aren't blocked by the permission classifier.
- **Lead and sidekick.** The lead plans, reviews and commits. Sidekicks implement and test. Use the repo skills (`create-module`, `create-entity`, `create-usecase`, `create-domain-event-handler`, `create-integration-event`) for scaffolding.
- **After each step:** tick its box in §6, and note any contract surprise in §7.

## 1. Decisions (binding for all steps)
**D1. Vapor owns LiqPay.**
- Port from `~/dev/fitnessart/fitnessart-backend`: `Sources/fitnessart/Integration/LiqPay/LiqPayPaymentGateway.swift`, `Modules/Payments/{Domain/Gateway/PaymentGateway.swift, Application/UseCase/HandlePaymentCallbackUseCase.swift, Presentation/Request/LiqPayCallbackEnvelope.swift}`.
- Vapor creates the checkout and serves the LiqPay `server_url` callback.
- Vapor must still write `accounts/{accountId}/checkout-sessions/{invoiceId}` in the shape Flutter reads (Flutter snapshots it).
- The extension is uninstalled at cutover (S17).

**D2. Trigger transport follows fitnessart.**
- *Production:* gen-1 Node forwarders in `cloud-functions/`, deployed with `gcloud`, no npm deps. They POST CloudEvents in binary mode (`ce-*` headers + JSON body) to Vapor `POST /`, with an OIDC bearer token from the metadata server.
  - `auth-forwarder` (exists).
  - New `firestore-forwarder` (S08).
- *Local:* an emulator bridge, as a functions codebase in `show-menu-firebase`. It uses firebase-functions **v1** triggers and POSTs the same envelope to `http://localhost:8080` with no auth. Reference: `~/dev/fitnessart/fitnessart-firebase/functions/src/{triggers,lib/cloudevents/cloudevents-formatter.ts}`.
- Vapor verifies OIDC with a port of fitnessart `EventarcAuthMiddleware` + `GoogleOIDCTokenVerifier` (`Integration/GoogleCloud/SchedulerAuthMiddleware.swift`). The check is bypassed in emulator mode.
- Keep the template's **stable `ce-id = context.eventId`**. Do not copy fitnessart's random UUID: the inbox de-duplicates on `ce-id`.

**D3. Wire contract kept, bugs fixed.**
- These stay exactly as Node had them: paths, success status codes, success bodies, and Firestore document shapes (Flutter reads them directly).
- The bugs listed in §4 are fixed.
- **Base path: `/api/v1/...`.** Flutter's base ends in `/api` and appends `/v1/...`; the harness base ends in `/api/v1`. `/health`, `/version` and `POST /` stay at the root.

**D4. One error envelope.**
- A central error middleware maps errors to HTTP and returns `{"error":{"code","message","details?"}}`. This replaces Node's two inconsistent formats.
- Status codes:

| Status | Meaning |
|---|---|
| 400 | malformed input |
| 401 | missing or invalid token |
| 403 | not allowed |
| 404 | not found |
| 409 | conflict, duplicate, version clash |
| 412 | stale `If-Match` |
| 422 | validation |
| 500 | anything else |

**D5. Authentication.**
- Port fitnessart's `Integration/Firebase/{FirebaseTokenVerifier,FirebaseIDToken,FirebaseBearerAuthenticator}.swift`.
- Emulator tokens are unsigned and are accepted **only** in emulator mode. `iss`, `aud`, `exp` and `sub` are still checked.
- **Admin = the `admin: true` claim in the token.** Node re-read the live user record; this change is deliberate. The harness re-mints tokens after setting claims, and Flutter never reads claims.
- The `Principal` gets `Role.admin`. It is bound through `RequestContext.$principal`.

**D6. Firestore is the contract.**
- Same project, same collections, **no data migration**.
- Models copy Node's field names exactly.
- Timestamps are Firestore `Timestamp`, not `Date`, in every collection a client reads.
- The template's `version` field is additive and is adopted lazily.
- IDs keep their prefixes: `plan-`, `feature-`, `order-`, `invoice-` + UUID.
- Subscription id is **derived from orderId**, so a duplicate activation becomes a no-op (S14).

**D7. Scheduled jobs.**
- Cloud Scheduler HTTP job → `POST /api/v1/subscriptions/jobs/check-expired`.
- Guarded by a port of fitnessart `SchedulerAuthMiddleware`: OIDC (`SCHEDULER_OIDC_AUDIENCE`, `SCHEDULER_ALLOWED_SERVICE_ACCOUNTS`) or the `X-Api-Key` header (`SCHEDULER_API_KEY`) for local runs.
- Vapor Queues is not used, because it doesn't run with `min-instances=0`.

**D8. Not ported:**
- `/echo/echo`, `/echo/environment` (leaks env vars), and `/playground/*` (hardcoded keys).
- The `DELETE /accounts/:a/subscriptions/:s` stub.
- Dead events and unused code (see the Node inventory below).
- The hardcoded `ADMIN_EMAILS`. It becomes the `ADMIN_EMAILS` env var on identity-blocking.

**D9. Price matching rule.**
- A purchase price matches a plan price when **duration + currency name + amount** are equal.
- Node required deep equality including `symbol/base/digits`. Flutter omits `currencyBase`/`currencyDigits`, so those must be optional in the DTO.

**D10. Node stays runnable as the baseline until S18.**
- Forwarders live in a **separate** functions codebase (`show-menu-firebase/forwarders`). For Vapor runs, emulators start with a dedicated config (`firebase emulators:start --config firebase.vapor.json --only auth,firestore,functions`) that loads only the forwarders.
- `test:node:emulated` keeps working against the old code.
- Verify `--config` support in S01; if it's missing, fall back to a separate `firebase.json` directory.

## 2. Node inventory → Vapor mapping (parity matrix)
| Node (show-menu-firebase/functions/src) | Contract | Vapor replacement | Step |
|---|---|---|---|
| `GET /api/v1/echo/hello` | 200 JSON string containing "Hello" | Echo route | S01 |
| `GET /api/v1/echo/version` | 200 text `vX+build, revision: …` | Echo route (from `BUILD_*` env) | S01 |
| `authenticate` / `authorize({isAdminRequired})` | 401 / 403. Admin gate also covers unmatched paths | Bearer authenticator + admin guard | S03 |
| `POST /api/v1/plans/features` | 200 FeatureResponse. Node had no validation | `CreateFeature` | S04 |
| `PUT /api/v1/plans/features/:featureId` | 200 FeatureResponse | `UpdateFeature` | S04 |
| `POST /api/v1/plans` | **200** PlanResponse; duplicate SKU → 409 (was 400) | `CreatePlan` | S05 |
| `GET /api/v1/plans/:id` | 200 PlanResponse; 404 | `GetPlan` query | S05 |
| *(new)* `GET /api/v1/plans` | admin list (harness expects 401 unauthenticated) | `ListPlans` query | S05 |
| `PUT /api/v1/plans/:id` | 200 PlanResponse (name, description) | `UpdatePlan` | S06 |
| `PUT /api/v1/plans/:id/activate` / `deactivate` | 200, empty body | `Activate/DeactivatePlan` | S06 |
| `PUT /api/v1/plans/:id/features` | 200 PlanResponse | `AddPlanFeature` | S06 |
| `DELETE /api/v1/plans/:id/features/:featureId` | 200, empty body | `RemovePlanFeature` | S06 |
| `triggers-userOnCreated` (v1 auth onCreate) | `users/{uid}` {id, email, name, avatarURL, accounts:[], createdAt, updatedAt}; admin claim for admin emails | auth-forwarder → `UserOnboard`; identity-blocking sets claim | S07 |
| `triggers-onAccountCreated` (`accounts/{accountId}` create) | `users/{creator}.accounts += id`; `accounts/{id}/permissions/{creator}` = {role:"owner", permissions:[]} | firestore-forwarder → `AccountCreated` → 2 inboxed handlers | S08 |
| `POST /api/v1/accounts/:accountId/purchases` | **200 text/plain invoice id** (`invoice-…`); 409 if a pending checkout session exists; 422 validation | `PurchaseSubscription` + LiqPay checkout | S09–S11 |
| `DELETE /api/v1/accounts/:accountId/purchases/:invoiceId` | 200; order → cancelled, session → cancelled. **Broken in Node** | `CancelPurchase` (fixed) | S12 |
| LiqPay extension `handleInvoicePlaced` + `handlePaymentStatus` webhook | session doc, `invoices/{id}/statuses` | Vapor checkout (S11) + `POST /api/v1/payments/liqpay/callback` | S11, S13 |
| `triggers-onInvoicePaymentStatusAdded` / `onCheckoutSessionUpdated` | invoice / order / subscription status | Replaced by in-process domain events from the callback (no Firestore trigger) | S13–S14 |
| `triggers-onCheckExpiredSubscriptions` (daily 00:00 UTC) | active subs with `expiresAt <= now-1d` → expired; `(now-1d, now]` → "expiring" event | Scheduler endpoint | S15 |

**Firestore collections Vapor owns or writes:**
- `users/{uid}` (+ `roles/*`, legacy, read-only)
- `accounts/{id}` (read; created by the client)
- `accounts/{id}/permissions/{uid}`, `accounts/{id}/orders/{orderId}`, `accounts/{id}/checkout-sessions/{invoiceId}`, `accounts/{id}/subscriptions/{subId}`
- `invoices/{id}` (+ `statuses/*`)
- `plans/{id}`, `features/{id}`
- Template infrastructure: `idempotency_keys`, `inbox_records`, `outbox`

**Flutter reads these directly** (exact shapes are mandatory): `plans`, `accounts/*/subscriptions`, `accounts/*/checkout-sessions`, `users/{uid}` (`.accounts`), `accounts/*/permissions/{uid}`.

## 3. Phase overview
| Phase | Steps | Harness milestone |
|---|---|---|
| 0 Foundation | S01–S03 | `test:smoke` green; 401 cases of `auth-rbac` green |
| 1 Catalog | S04–S06 | `plans-lifecycle` + all of `auth-rbac` green |
| 2 Identity & Accounts | S07–S08 | `user-onboarding` green |
| 3 Payments & Purchases | S09–S13 | `purchase-flow` green; signed LiqPay callback e2e (Swift emulator test) |
| 4 Subscriptions | S14–S15 | Subscription lifecycle + expiry emulator tests |
| 5 Deploy & Cutover | S16–S18 | Deployed to `show-menu-dev`; Flutter switched; Node and extension removed |

## 4. Known Node bugs to fix (do not port)
1. `CancelPurchaseUseCase` fetches the order by **invoiceId** and reads the session from the literal path `accounts/{accountId}/…` → S12.
2. The extension writes **two** `statuses` docs per callback, and `ActivateSubscription` uses a non-transactional `findSubscriptionByOrderId` → duplicate subscriptions → S13/S14 (inbox + deterministic id).
3. `ExceptionBase` throws a TypeError outside HTTP requests (every trigger path) → N/A, the error model is new.
4. A failed checkout never fails the order (the session is `create`d, not updated) → S11.
5. JSONata `description: orderId.value` is undefined; periodicity lookup `annually` vs domain `yearly` → S09 mapping.
6. Admin users get no `users/{uid}` doc ("Customer not found" on purchase) → S07.
7. `Plan.removeFeature` emits `plan.feature.added` → S06.
8. `Subscription.activate()` extends `expiresAt` even when the transition is invalid; invalid FSM transitions are silently swallowed → S14 (throw a domain error and log).
9. No account-membership check on `/accounts/:accountId/*` → S11 (`AccountMemberAbility`).
10. Domain-event registry created outside `runTransaction` → duplicate events on retry → N/A (the template's UoW is correct).
11. The expiry job does an N+1 scan of all accounts inside one transaction (500-write cap) → S15.
12. `UserMapper` wraps accounts as `UserId`; feature create/update have no validation → S04/S07.

## 5. Steps

### Phase 0: Foundation

#### S01: Local loop, `/api` prefix, Echo, CI
- **Goal:** a working Vapor + emulators + harness loop, with `test:smoke` green.
- **Scope (backend):**
  - Make `GCP_CLOUD_RUN_SERVICE_URL` optional in emulator mode. Today boot throws everywhere, and the error message names the wrong variable (`App/Vapor+GCP.swift`).
  - Pin `FirebaseAPI` to a revision instead of `branch: main` (`Package.swift`).
  - Introduce an `api` route group in `routes.swift`, and move the module routes from `/v1` to `/api/v1`.
  - Add an `Echo` module (Presentation only is fine):
    - `GET /api/v1/echo/hello` → JSON string `"Hello from ShowMenuBackend!"`.
    - `GET /api/v1/echo/version` → text built from `BUILD_*` env + `K_REVISION`.
  - Replace the hardcoded `GET /version` "0.0.1" with the same build info.
  - Add a `Makefile` (or `scripts/`): `emulators`, `run-local` (`PORT=8080 GCP_PROJECT_ID=show-menu-dev FIRESTORE_EMULATOR_HOST=127.0.0.1:9002 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 swift run Run serve`), `harness` (`npm --prefix ../show-menu-firebase/test-harness run test:vapor:local`).
  - Add a CI workflow `.github/workflows/ci.yml` running `swift build` + `swift test`.
- **Scope (show-menu-firebase):** add `firebase.vapor.json` (auth 9099, firestore 9002, functions 9001, UI; functions source = `forwarders`). Create an empty `forwarders/` codebase skeleton (TS, firebase-functions v1, Node 20). Check that `--config` works (D10).
- **Out of scope:** auth, modules.
- **Done:** `swift test` green; `make run-local` boots against the emulators; `npm run test:smoke` (Vapor target) green.

#### S02: Error contract and shared kernel
- **Goal:** primitives every module needs.
- **Scope:**
  - Central `ErrorMiddleware` (D4) that maps `ApplicationError`, `ValidationError`, `DomainError`, `ConcurrencyError`, `AuthorizationError` (403; it currently surfaces as 500), `FirestoreError`, `DecodingError`, `Abort`, `IdempotencyError`.
  - A DTO validation convention (Vapor `Validatable` at the edge, domain invariants in entities).
  - Document both in `docs/conventions/HTTPErrors.md`.
  - Shared kernel at `Modules/Shared/Domain/` (or `Lib/` if generic):
    - `LocalizedString` (a non-empty `[lang: String]`, Codable as a plain map)
    - `Currency {name, symbol?, base?, digits?}`, `Price {currency, amount >= 0}`
    - `SubscriptionDuration` (`daily|weekly|monthly|yearly`, with `add(to:)`)
    - `PrefixedId` generator (`plan-<uuid>`)
    - Firestore `Timestamp` ↔ `Date` mapping helpers
    - `PriceDTO` (flat `currencyName`, `currencySymbol?`, `currencyBase?`, `currencyDigits?`, `amount`)
- **References:** Node `app/modules/shared/*`, `app/core/exceptions/woopsify.ts`; fitnessart controller `asAbort` pattern (`Modules/Scheduling/Presentation/Controller/SchedulingController.swift`).
- **Done:** unit tests for the middleware mapping table and the value objects; Items routes still behave the same.

#### S03: Firebase ID-token authentication and admin guard
- **Goal:** authenticated `/api/v1` with Node's 401/403 semantics.
- **Scope:**
  - Port the fitnessart verifier, token and authenticator (D5) into `Integration/Firebase/`. JWKS: `securetoken@system`, cached by `max-age`.
  - Build a `Principal` from claims (`admin == true` → `Role.admin`) and bind `RequestContext.$principal` in middleware. Set `CommandMetadata.userId` from the principal (`App/CQRS+Vapor.swift`).
  - Route groups: `public` (echo), `authenticated` (`/accounts/*`), `admin` (`/plans/*`).
  - **Trap:** Node's admin `use()` also returned 401/403 for unmatched paths, and the harness checks `GET /plans` → 401. Make sure `/plans` routes exist under the guarded group: a temporary `GET /plans` stub returning `[]` is fine until S05.
- **Done:** unit tests (valid, expired, wrong `aud`/`iss`, unsigned outside emulator → 401; non-admin → 403); the 401 cases in `auth-rbac.test.ts` green.

### Phase 1: Catalog (Plans and Features)

#### S04: Catalog module, Features
- **Goal:** the `Catalog` module skeleton (via `create-module`) plus the Feature aggregate.
- **Scope:**
  - `Feature` (AggregateRoot):
    - Props: `name: LocalizedString`, `category` (`ai|technicalSupport`), `description: LocalizedString?`.
    - Behaviour: `create`, `update`.
    - Semantic events: `FeatureAdded`, `FeatureUpdated`.
  - `FeatureModel` ↔ `features/{id}` {id, category, name, description, createdAt, updatedAt}.
  - `POST /api/v1/plans/features` (200 FeatureResponse `{id, createdAt, updatedAt, category, name, description?}`, `description` omitted when null).
  - `PUT /api/v1/plans/features/:featureId` (partial update).
  - **Add validation** (Node had none).
  - **Delete the Items demo module** (sources, tests, routes, deps). Re-point `.claude/skills/*` and `AGENTS.md` ("mirror the Items module") to Catalog.
- **References:** Node `app/modules/plans/{domain/entity/feature.entity.ts, presentation/controller/feature.controller.ts, application/dto/*feature*}`.
- **Done:** unit tests; `plans-lifecycle` "create feature" case green.

#### S05: Plans, aggregate, create, get, list
- **Scope:**
  - `Plan` (AggregateRoot):
    - Props: `SKU, name, description, isActive, prices: [PlanPrice], features: [PlanFeature]`.
    - Invariants: SKU non-empty; ≥1 price and ≥1 feature; unique durations and featureIds.
    - `PlanFeature {featureId, quota: FeatureQuota{unit: duration|count|level, limit}}`, `PlanPrice {price, duration}`.
    - `Plan.matches(price:)` per D9.
  - `PlanModel` ↔ `plans/{id}` with nested `prices[].price.currency{name,symbol,base,digits}` (exact Node shape).
  - Create: SKU uniqueness via a query inside the transaction → 409.
  - Endpoints: `POST /plans` (**200**), `GET /plans/:id`, `GET /plans` (admin list; replaces the S03 stub). PlanResponse matches Node `plan.response.dto.ts`.
- **Done:** unit tests; `plans-lifecycle` create and get cases green; all of `auth-rbac.test.ts` green.

#### S06: Plans, mutations
- **Scope:** `PUT /plans/:id` (name, description), `PUT /plans/:id/activate|deactivate` (200, empty body, idempotent), `PUT /plans/:id/features` (add → PlanResponse), `DELETE /plans/:id/features/:featureId` (404 if absent; emit **FeatureRemoved**, fixing bug 7). Optional: ETag/If-Match on PUT.
- **Done:** unit tests; **`plans-lifecycle.test.ts` fully green.**

### Phase 2: Identity and Accounts

#### S07: Users, schema, onboarding, admin claim, webhook auth
- **Goal:** Auth user created → `users/{uid}` doc; admin claim; authenticated webhook.
- **Scope (backend):**
  - **Reshape IAM `User` to the existing schema:** `users/{uid}` {id, email, name, avatarURL, accounts: [String], createdAt, updatedAt} as Timestamps. Drop or keep the extra template fields only if they don't collide (Flutter reads `.accounts`).
  - `UserOnboardUseCase` creates the doc for every user, admins included (bug 6).
  - Add `User.addAccount/removeAccount` (idempotent) for S08.
  - Port fitnessart `EventarcAuthMiddleware` + `GoogleOIDCTokenVerifier` onto `POST /`: env `EVENTARC_OIDC_AUDIENCE`, `EVENTARC_ALLOWED_SERVICE_ACCOUNTS`, bypassed in emulator mode.
  - `cloud-functions/identity-blocking`: implement `decideUserClaims` → `{admin: true}` when the email is in `ADMIN_EMAILS` (env) and verified. Reference: fitnessart `cloud-functions/identity-blocking` `ROLE_DEFINITIONS`.
  - **Prerequisite check:** is `show-menu-dev` upgraded to Identity Platform? If not, either upgrade it (one-way) or set the claim from Vapor on `user.created` through the Identity Toolkit `accounts:update` `customAttributes` (new `IdentityToolkitClient`). Record the choice in §7.
- **Scope (show-menu-firebase/forwarders):** `onUserCreated` / `onUserDeleted` v1 auth triggers → CloudEvents POST to `BACKEND_WEBHOOK_URL ?? http://localhost:8080`, `ce-id = context.eventId`. Port `cloudevents-formatter.ts` from fitnessart-firebase. Add a vitest test.
- **Done:** unit tests; `user-onboarding.test.ts` test 1 green (Vapor target); the webhook rejects a missing or wrong OIDC token outside the emulator (unit test).

#### S08: Accounts, link to creator and owner permission
- **Goal:** replace `onAccountCreated`.
- **Scope (backend):**
  - New `cloud-functions/firestore-forwarder`: gen-1, `--trigger-event providers/cloud.firestore/eventTypes/document.create --trigger-resource "projects/$P/databases/(default)/documents/accounts/{accountId}"`, CloudEvents `ce-type: google.cloud.firestore.document.v1.created`, `ce-subject: documents/accounts/{id}`. Body: `{path, documentId, data}`, with fields flattened to plain JSON and Timestamps as ISO. README in the auth-forwarder format.
  - Vapor: extend `CloudEventsParser` and the webhook for the new type.
  - `Accounts` module (read-side `Account {name, creator}` + mapper for `accounts/{id}`).
  - `AccountCreatedIntegrationEvent`, handled by two `InboxedCommandHandler`s:
    - `LinkAccountToCreator`: user aggregate `addAccount` → `users/{uid}.accounts`.
    - `GrantAccountOwnerPermission`: `accounts/{id}/permissions/{uid}` = `{role:"owner", permissions:[]}`.
- **Scope (show-menu-firebase/forwarders):** a v1 `firestore.document("accounts/{accountId}").onCreate` bridge with the same envelope.
- **Done:** unit tests (incl. redelivery skipped by the inbox); **`user-onboarding.test.ts` fully green.**

### Phase 3: Payments and Purchases

#### S09: LiqPay integration client
- **Scope:**
  - `Integration/LiqPay/`: request signing (`base64(sha1(privateKey + data + privateKey))`), `checkout` (form POST `https://www.liqpay.ua/api/3/checkout` → 3xx `Location` = payment page URL), `status` (`POST /request {action:"status", version:3, order_id}`), callback verification and decoding (`data` + `signature`).
  - A `PaymentGateway` port in the Purchases domain. `FakePaymentGateway` is used when the keys are missing or in emulator mode, so the harness stays offline.
  - Checkout request mapping from an invoice:
    - `action` = `subscribe` for plan purchases, else `pay`.
    - `amount` = Σ amount×qty; `currency` from the first line.
    - `description` = `Order #<orderId>` (fix 5).
    - `order_id` = invoiceId.
    - `subscribe_periodicity` = `day|week|month|year` from `SubscriptionDuration` (fix 5).
    - `server_url` = `LIQPAY_CALLBACK_URL`, `result_url` = `LIQPAY_RESULT_URL`.
  - Wrap the client in `RetryPolicy` (transient errors only) and a `CircuitBreaker`.
  - Env and secrets: `LIQPAY_PUBLIC_KEY`, `LIQPAY_PRIVATE_KEY` (Secret Manager in production), `LIQPAY_CALLBACK_URL`, `LIQPAY_RESULT_URL`.
- **References:** fitnessart `Integration/LiqPay/LiqPayPaymentGateway.swift`; `../show-menu-firebase/playground/liqpay.sh` (signing only; never copy its keys); extension source `~/dev/rozd/liqpay-firebase-extension/functions/src/{index,helpers}.ts` (status mapping).
- **Done:** unit tests with deterministic signing vectors made from test keys; no network in tests.

#### S10: Purchases domain model
- **Scope:**
  - `Order` (AggregateRoot):
    - Props: `accountId, customerId, lineItems: [OrderProduct], discounts, shipment, customer, status, invoiceId?`.
    - FSM on `Lib/FSM/FiniteStateMachine`: `created→completed|failed|cancelled`, `cancelled→completed|failed`, `completed→refunded`. Invalid transitions **throw** a domain error.
    - Semantic events: `OrderCreated/Completed/Failed/Cancelled`.
  - `Invoice` (AggregateRoot in Vapor, so it can raise `InvoicePaid` etc.):
    - FSM `pending→paid|cancelled|failed`, `paid→refunded`.
    - Getters: amount, currency, `paymentAction`.
  - Value objects: `OrderProduct`, `PlanOrderProduct(duration)`, `CustomerInfo`, `ShipmentInfo(method: electronic)`, `OrderDiscount`.
  - Models that copy **exactly**:
    - `accounts/{a}/orders/{id}`: `lineItems[{sku, productId, productName, productPrice{currency{…},amount}, quantity, duration?, productDetails?}]`, `discounts`, `shipment{method,address}`, `customer{name,email,phone,address}`, `status`, `userInfo: null`, `invoiceId`, timestamps.
    - `invoices/{id}`: `orderId, accountId, customerId, transactionId, status, issueDate, dueDate, orderDate, customer, shipmentMethod, shipmentAddress, lineItems, discounts`, timestamps.
  - `CheckoutSession` model for `accounts/{a}/checkout-sessions/{invoiceId}`: `{status, invoiceId, orderId, paymentPageURL, transactionId, errorCode, errorMessage, errorDetails}`.
  - **Before fixing the status vocabulary, read Flutter's parser** (`show-menu-flutter/libs/show_menu_common/lib/app/modules/products/**/firestore_checkout_session_data_source.dart` + serialization). The extension wrote `pending|success|failure|cancelled`, but the harness contract says `pending|completed|expired|cancelled`. **Flutter wins.**
- **References:** Node `app/modules/purchases/domain/**`, `infrastructure/model/*`, `application/mapper/*`.
- **Done:** unit tests (FSM tables, mapper round-trips against the Node doc shapes).

#### S11: Purchase subscription endpoint
- **Scope:** `POST /api/v1/accounts/:accountId/purchases`. The command handler conforms to `IdempotentCommandHandler`. Flow of the use case:
  1. Load the account (404).
  2. **`AccountMemberAbility`** (PEP; allow if `account.creator == principal`, a `permissions/{uid}` doc exists, or admin), fixing bug 9.
  3. Load the plan (404); not active → 422; price mismatch per D9 → 422.
  4. Load the user (404, or fall back to token email; decide and document).
  5. Pending session for the account → 409.
  6. In one transaction: Order + Invoice + session `{status: pending, paymentPageURL: null}`.
  7. After commit: `PaymentGateway.checkout`, then update the session `paymentPageURL`. On gateway failure, set session `failure` + error fields and fail the order (fix 4). Do this in a post-commit domain-event handler for `OrderCreated` or as an explicit post-commit step, since the external call must stay outside the transaction.
  8. Response: **200 `text/plain` invoice id.**
  - DTO: `planId`, `price{duration, price{amount, currencyName, currencySymbol?, currencyBase?, currencyDigits?}}`; unknown fields ignored.
- **Done:** unit tests; `purchase-flow.test.ts` "create order and invoice" + "409 on pending session" green.

#### S12: Cancel purchase
- **Scope:** `DELETE /api/v1/accounts/:accountId/purchases/:invoiceId`. Membership check → load the invoice (404; must belong to the account) → load the order via **`invoice.orderId`** → `order.cancel` + `invoice.cancel` + session `{status: cancelled}` at the real tokenized path, in one transaction → 200. If the invoice isn't pending, decide between 409 and an idempotent 200, and document it. The harness's extra workaround docs must not matter.
- **Done:** unit tests; **`purchase-flow.test.ts` fully green.**

#### S13: LiqPay callback (replaces the extension webhook and the payment triggers)
- **Scope:** `POST /api/v1/payments/liqpay/callback`. Public; form-encoded `data` + `signature`; **signature verified** (401/400 otherwise). Handled by an inboxed command keyed on `(order_id, status, payment_id)`, so duplicate callbacks are no-ops. In one transaction:
  - Append the raw payload to `invoices/{id}/statuses/{auto}` (audit; keeps the old shape).
  - Map the LiqPay status to:
    - session status (`success|subscribed→success`, `error|failure→failure`, `reversed|unsubscribed→cancelled`, else `pending`, unless S10 decided otherwise);
    - invoice status (`→paid|failed|refunded|cancelled`);
    - order transition.
  - Domain events `InvoicePaid/Failed/Refunded/Cancelled` are dispatched after commit.
  - Optional hardening: confirm with `status` API before acting on `success` (the extension did this). Decide and document.
  - Respond 200 quickly. LiqPay retries on non-2xx.
- **Done:** unit tests (bad signature, duplicate callback, each status); an emulator integration test that posts a signed fake callback and asserts the invoice, order and session docs.

### Phase 4: Subscriptions

#### S14: Subscriptions lifecycle
- **Scope:** `Subscriptions` module.
  - `Subscription` (AggregateRoot):
    - Props: `planId, orderId, accountId, status, startedAt, expiresAt, suspensionReason?, cancellationReason?`.
    - FSM: `active→expired|suspended|cancelled`, `expired→active`, `suspended→active|cancelled`. Invalid transitions throw, and `expiresAt` is never changed on an invalid transition (bug 8).
  - **Deterministic id from orderId**, created with a create precondition (bug 2).
  - `accounts/{a}/subscriptions/{id}` exact schema; legacy `sub:<uuid>` docs must stay readable.
  - Domain-event handlers on the S13 events:
    - `InvoicePaid` → `ActivateSubscription` (create or extend by plan duration from the `PlanOrderProduct`).
    - `InvoiceFailed` → `Suspend("Payment failed")`.
    - `InvoiceRefunded` / `InvoiceCancelled` → `Cancel("Payment <status>")`.
  - Each handler runs its own unit of work, because these are follow-on work on another aggregate.
- **Done:** unit tests; an emulator e2e test: purchase → signed `success` callback → active subscription with correct `expiresAt`; a duplicate callback leaves exactly one subscription.

#### S15: Expiration job
- **Scope:**
  - Port fitnessart `SchedulerAuthMiddleware` (OIDC + `X-Api-Key`).
  - `POST /api/v1/subscriptions/jobs/check-expired`. Query `status == active && expiresAt <= now+1d`:
    - **Check whether FirebaseAPI supports collection-group queries (`allDescendants`).** If it does, add a collection-group index in `../show-menu-firebase/firestore.indexes.json`.
    - Otherwise iterate the accounts, bounded and paged.
  - `expired` when `expiresAt <= now-1d`; emit `SubscriptionExpiring` for `(now-1d, now]`. Per-subscription unit of work, or chunks under the 500-write cap; idempotent on re-run.
  - Response: JSON summary `{scanned, expired, expiring}`.
  - Document the Cloud Scheduler job (`0 0 * * *`, UTC, the same as Node).
- **Done:** unit tests; an emulator test with seeded subscriptions.

### Phase 5: Deploy and Cutover

#### S16: Deploy pipeline and infrastructure (`show-menu-dev`)
- **Scope:**
  - `cloudbuild.yaml`: `--set-env-vars=^|^…` with `GCP_PROJECT_ID`, `GCP_CLOUD_RUN_SERVICE_URL`, `EVENTARC_OIDC_AUDIENCE`, `SCHEDULER_OIDC_AUDIENCE` (all the deterministic `https://<svc>-<projectNumber>.<region>.run.app`; a mismatch silently 401s, see the fitnessart incident note), `EVENTARC_ALLOWED_SERVICE_ACCOUNTS`, `SCHEDULER_ALLOWED_SERVICE_ACCOUNTS`, `LIQPAY_CALLBACK_URL`, `LIQPAY_RESULT_URL`, `BUILD_*`.
  - `--update-secrets` for the LiqPay keys. Region `us-central1` (matching the functions and Firestore).
  - `--allow-unauthenticated` stays: all auth happens in the app.
  - Deploy `auth-forwarder`, `firestore-forwarder` and `identity-blocking` (with `ADMIN_EMAILS`). Grant `run.invoker`. Create the Cloud Scheduler job.
  - Write `docs/operations/deploy.md` (runbook + verification curl commands). Add CI deploy only if wanted.
- **Done:** service live on `show-menu-dev`; the smoke HTTP checks pass against the deployed URL; creating a test Auth user produces `users/{uid}`; a test account write links it.

#### S17: Cutover (multi-repo)
- **Scope:**
  - **Flutter:** make `api` use `String.fromEnvironment('API_BASE_URL')` (Cloud Run URL + `/api`) with the emulator default only in debug (`libs/show_menu_common/lib/app/core/constants.dart`). Set it per flavor.
  - **LiqPay:** point the merchant callback at the Vapor callback.
  - **Drain:** wait for or close pending checkout sessions created by the extension.
  - **Firebase:** uninstall the extension; `firebase functions:delete` the Node functions (`default`, `triggers-*`) on `show-menu-dev`.
  - **Rules:** `firestore.rules` is open "test mode" and **expires 2027-01-01**. Write real rules: clients read `plans`, `subscriptions`, `checkout-sessions`, `permissions` and their own `users/{uid}`; clients keep write access only to the content they write today (accounts create, places, menus, settings); deny client writes to backend-owned collections. Rules-test them in the emulator.
  - **Rotate** the LiqPay sandbox keys committed in `show-menu-firebase/playground/liqpay.sh` and `functions/src/app/modules/playground/**`.
- **Done:** the Flutter dev build purchases end to end on `show-menu-dev` through Vapor; there are no Node functions deployed.

#### S18: Decommission and docs
- **Scope:**
  - Remove `show-menu-firebase/functions` (Node app + `__tests__`), `extensions/` and `playground/`. Keep the rules, indexes, `forwarders/` and `test-harness/`.
  - Make the Vapor target the harness default. Drop the `test:node:*` scripts.
  - Update `AGENTS.md`/`README.md` here (modules, endpoints, env vars, triggers, scheduler) and the firebase repo README.
- **Done:** both repos build and test green; the harness passes against Vapor with no Node code left.

## 6. Progress checklist
- [x] S01 Local loop / `/api` / Echo / CI
- [x] S02 Error contract and shared kernel
- [x] S03 Authentication and admin guard
- [x] S04 Catalog: Features (+ remove Items)
- [ ] S05 Plans: create, get, list
- [ ] S06 Plans: mutations
- [ ] S07 Users onboarding, admin claim, webhook auth
- [ ] S08 Accounts linking (firestore-forwarder)
- [ ] S09 LiqPay client
- [ ] S10 Purchases domain
- [ ] S11 Purchase endpoint
- [ ] S12 Cancel purchase
- [ ] S13 LiqPay callback
- [ ] S14 Subscriptions lifecycle
- [ ] S15 Expiration job
- [ ] S16 Deploy pipeline
- [ ] S17 Cutover
- [ ] S18 Decommission

## 7. Open questions and decision log (fill in as you go)
- Identity Platform upgrade on `show-menu-dev`, or claim set from Vapor? (S07)
- Checkout-session status vocabulary as Flutter parses it. (S10)
- Purchase when `users/{uid}` is missing: 404, or token-email fallback? (S11)
- Cancel of a non-pending invoice: 409, or idempotent 200? (S12)
- Confirm the LiqPay callback with the status API? (S13)
- FirebaseAPI collection-group support. (S15)
- ~~`firebase emulators:start --config` support for the forwarders-only config. (S01)~~ **Answered (S01): supported** (firebase-tools 15.31.0). `firebase emulators:start --config firebase.vapor.json --only auth,firestore,functions --project show-menu-dev`, run from `show-menu-firebase`, loads only the `forwarders` codebase (log: `Loaded functions definitions from source`, an empty codebase is fine). No fallback needed. `make emulators` wraps it (needs `cd ../show-menu-firebase`).

### Decisions taken (S01)
- **S01:** Local loop commands. `make emulators` (terminal 1), `make run-local` (terminal 2, `PORT=8080`, emulator env on 127.0.0.1), `make harness HARNESS_ARGS=smoke` (terminal 3). Equivalent: `npm --prefix ../show-menu-firebase/test-harness run test:vapor:local -- <pattern>`.
- **S01:** `forwarders/` needs `npm install && npm run build` once (and after edits; `lib/` is gitignored) before the emulators load it. The functions emulator warns about Node 20 vs the host Node; harmless.
- **S01:** `GCP_CLOUD_RUN_SERVICE_URL` is optional only in emulator mode (defaults to `http://localhost:$PORT`, 8080). Everywhere else it is still required, and the error now names the right variable.
- **S01:** Route modules keep their own `v1` segment and are registered on `app.grouped("api")` in `routes.swift`. Later modules must register on `api`, not `app`. Idempotency header validation is still global.
- **S01:** `GET /version` and `GET /api/v1/echo/version` share `Environment.buildInfo`: `v0.0.1+<BUILD_BRANCH_NAME>[-<BUILD_SHORT_SHA>], revision: <K_REVISION|unknown>`. The `0.0.1` is hardcoded (Node read `version.json`).
- **S01:** FirebaseAPI pinned to revision `c5fe828790f7d7bf443dda42bbcba3fc3fe72a6a` (the previously resolved `main`).
- **S01:** `firebase.vapor.json` omits hosting/storage/remoteconfig/extensions on purpose (no LiqPay extension in the Vapor loop). It does include firestore rules + indexes.
- **S01:** CI runs in a `swift:6.2-noble` container on ubuntu-latest (not yet run on GitHub).

### Decisions taken (S02)
- **S02:** Harness only asserts status codes (`res.status`) — no check on the error body or `code` values, so the envelope is unconstrained by it. Codes are snake_case strings, listed in `docs/conventions/HTTPErrors.md`.
- **S02:** `ValidationError` → 422, other `DomainError` → 409 (`domain_rule_violation`), `ApplicationError.invalidInput` → 422, `FirestoreError` transient → 503 (matches existing controllers). `Item.Error` still gives 400 because `ItemController` catches it first (Items is removed in S04).
- **S02:** `app.useErrorEnvelope()` wipes `app.middleware` and installs `HTTPErrorMiddleware`; it must stay the first call in `configure`. Later steps add auth middleware after it.
- **S02:** FirebaseAPI `Timestamp(_ date:)` truncates sub-seconds and `Date(timestamp:)` divides nanos by 1e6 (bug). Use `Timestamp(exact:)` / `.asDate` from `Integration/Firestore/Firestore+Timestamp.swift` in new models.
- **S02:** `Currency` encodes absent `symbol/base/digits` as explicit `null` (Node shape); whether the Firestore encoder writes `null` for them is unverified until a model stores it (S04/S05 mapper round-trip).
- **S02:** `Price.amount` is `Double`; `PrefixedEntityId` protocol gives `generate()` = `prefix + lowercase uuid`. Value objects live in `Modules/Shared/Domain`, `PriceDTO` in `Modules/Shared/Application/DTO`.

### Decisions taken (S03)
- **S03:** Added `vapor/jwt` (`JWT` product, `from: 5.1.0`) to `Package.swift`; `Package.resolved` changed accordingly.
- **S03:** Admin = top-level `admin: true` claim (`FirebaseIDToken.admin`); `FirebasePrincipal` (`Integration/Firebase/FirebaseBearerAuthenticator.swift`) maps it to the existing `Role.admin` (declared in IAM's `AdminRoleVoter.swift`). No `role` claim (fitnessart's) is read.
- **S03:** Route groups in `routes.swift`: `publicRoutes` (= `api`; echo), `authenticated` (`FirebaseAuthMiddleware`: any valid token), `admin` (authenticated + `RequireAdminMiddleware`). `FirebaseAuthMiddleware` replaces fitnessart's Authenticator + guard pair: it throws `Abort(.unauthorized)` itself and binds `RequestContext.$principal` around `next`. Missing/invalid/expired/wrong-aud/iss → 401; non-admin → 403 (`AuthorizationError.denied`); `RequireAdminMiddleware` with no principal → 401. All via the S02 envelope.
- **S03:** Existing **Items and IAM (`/users`) routes moved to `authenticated`** (any valid token, not admin; previously public). Conservative choice; Items is deleted in S04. Later modules must register on `authenticated`/`admin`, not `api`, unless deliberately public.
- **S03:** Vapor skips group middleware when no route matches, so Node's "401/403 for unmatched `/plans/*`" is reproduced by `PlansGuardRouteV1` (`Integration/Vapor/`): `GET /plans` → `[]` stub plus a guarded catch-all `/plans/**` → 404 (admins). S05 replaces the stub but must keep the catch-all (or an equivalent guard) until the real routes cover the harness paths.
- **S03:** `CommandMetadata(req:)` now takes `userId` from `RequestContext.principal?.id` (nil on public routes). It relies on being called inside the middleware's task-local scope, i.e. within a handler.
- **S03 (hardening):** Signed path accepts only `alg: RS256` with a `kid` that is present in the fetched JWKS (jwt-kit would otherwise fall back to a default signer on an unknown kid). JWKS fetch is injectable (`JWKSFetcher`), cached per `max-age` clamped to [60 s, 24 h], concurrent refreshes coalesced into one in-flight task, stale keys served (retry after 60 s) if a refresh fails. A fetch failure with nothing cached → `FirebaseJWKSUnavailableError` (`AbortError`, 503 `service_unavailable`), never 401. `iat` and `auth_time` must not be later than now + 60 s.
- **S03 (bug found):** the emulator path decoded the payload with a default `JSONDecoder`, which reads epoch seconds relative to 2001 (+31 years); fixed with `.secondsSince1970`. Any future hand-rolled JWT decoding must do the same.
- **S03:** The verifier is built lazily by `app.firebaseTokenVerifier` (`FirebaseTokenVerifier+Vapor.swift`) from `app.gcp`; unsigned tokens accepted only when `gcp.config.environment.isEmulator`. JWKS is cached by `Cache-Control: max-age` (default 1h). The signed RS256 path is unit-tested with in-test RSA keys served by a fake JWKS fetcher; it has not been run against Google's live JWKS.
- **S03:** Harness `auth-rbac`: all 4 cases pass (401 no header, 401 invalid token, 403 regular user, admin not 401/403). `smoke` 2/2 pass.

### Decisions taken (S04)
- **S04:** Catalog scaffolded by hand following the `create-module`/`create-entity` skills (they ask interactive questions); delivers only what S04 needs — `Feature` create + update, no Get/List query handlers (S05 brings the first list). Skills and `AGENTS.md` now point at Catalog; the Items module, its tests, routes and `Application.Dependencies` entries are deleted.
- **S04:** `features/{id}` doc = Node's `{id, category, name, description, createdAt, updatedAt}` with Timestamps, **plus** the template's additive `version` Int (D6, lazily adopted: absent decodes to `.none`, first Vapor write sets it). `description` is written as an explicit `null` (Node's `toPersistence` passes `null`) via FirestoreAPI's `@ExplicitNull`; the response omits it when null. `id` is a plain field in the model, **not** `@DocumentID`: the FirestoreEncoder skips `@DocumentID`, and Node stores `id` inside the document. `ExplicitNull` is made `@retroactive @unchecked Sendable` in `FeatureModel.swift`. Decoding requires the `description` key to be present (it always is, Node writes `null`).
- **S04:** Response dates are JS `toISOString()` strings (`2026-01-02T03:04:05.678Z`, UTC, ms). `POST /plans/features` answers **200**.
- **S04:** Validation (Node had none): category must be `ai|technicalSupport`; `name` required; every `name`/`description` text non-blank; empty `name`/`description` map rejected (`LocalizedString.Error.empty`). All → 422 `validation_failed`. Request payload fields are all optional `String`/`[String:String]` so that missing/invalid values are domain errors (422), not 400 decode errors. Unknown `featureId` → 404.
- **S04:** `PUT` is partial like Node (`props.x || this.x`): `null`/absent keeps the current value, so a stored `description` can be replaced but never cleared. An empty body still bumps `updatedAt` and records the event (Node parity).
- **S04:** Semantic events `FeatureAdded`/`FeatureUpdated` are extra kinds on `FeatureEventKind` (`featureAdded` = `"feature.added"`, `featureModified` = `"feature.updated"`); the Repository still adds lifecycle `created`/`updated`.
- **S04:** `Timestamp(exact:)` now rounds to whole microseconds (Firestore's precision). A ms-aligned Node timestamp (`…123 ms`) went `Date` → `122_999_907 ns` on write-back, which Node's `toDate()` floors to `…122 ms`; every Feature update rewrites `createdAt`, so this was a real 1 ms drift.
- **S04:** Idempotency and ETag/If-Match are now **unwired** (the only users were the Items endpoints). AGENTS.md says so; S11 (`IdempotentCommandHandler`) and S06 (optional ETag) re-wire them.
- **S04:** Feature routes are on the `admin` group next to `PlansGuardRouteV1`; the explicit `POST/PUT /plans/features[/:id]` win over the guard's `/plans/**` catch-all. The guard is untouched.
- **S04:** Harness `plans-lifecycle`: "create a Feature" ✓; "create Plan", "activate Plan", "fetch Plan" ✕ (S05/S06 scope, plans don't exist yet). `auth-rbac` 4/4 ✓, `smoke` 2/2 ✓.

## 8. Risks
- **Contract drift in client-read Firestore docs.** Mitigation: mapper round-trip tests against Node doc fixtures (S04–S14), plus a Flutter smoke run before S17.
- **OIDC audience mismatch silently drops events.** Mitigation: the deterministic URL form + a startup warning when the audience env is missing (port the fitnessart behaviour).
- **Forwarder delivery is fire-and-forget**, so an event is lost if Vapor is down. Accept for now (the same as fitnessart). The inbox handles redelivery; consider retry-on-failure for gen-1 later.
- **The firestore rules expiry (2027-01-01)** is a hard deadline that does not depend on the migration. Schedule S17's rules part early if the migration slips.
- **In-flight extension sessions during cutover.** Mitigation: the drain step in S17.
