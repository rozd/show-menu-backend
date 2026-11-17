# Restart from the standalone template

The backend was restarted from `vapor-standalone-template` (branch `main`, no Temporal) in the
same repository, on 2026-11-17. This document records why, what was kept and dropped, the
decisions taken, and the backlog of things that must be redesigned rather than ported.

## Why

Two rulings accepted on 2026-11-13 change the stack:

- **PostgreSQL is the system of record**, with the Backend API as its only writer
  (`2026-11-13-astro-showcase-react-dashboard-and-postgresql`, accepted).
- **Passage replaces Firebase Auth** (`2026-11-13-passage-replaces-firebase-auth`, accepted).

Contract `show-menu-contracts` **0.6.0** is reshaped around Business. The old code was
Firestore/Firebase throughout and pinned contract **0.2.0**, and every billing operation it
implemented was removed or reshaped in 0.6.0. Porting file by file would have kept the wrong
shape, so the code restarts from the template and ports only what survives.

## What the restart is

- The template's `main` branch (not its `feat/temporal-workflows` working tree): Vapor, Fluent
  (SQLite by default, Postgres via `DATABASE_URL`), Passage, DDD + CQRS `Lib/`, the IAM module
  as the pattern example. **No Temporal.**
- Repository identity, CI secrets, release-please configuration and Cloud Build deploy are kept.
- The HTTP API is generated from `show-menu-contracts` 0.6.0. Implemented operations:
  `getHealth` and `getVersion` (`/api/v1/health`, `/api/v1/version`). Every other operation
  answers `501 not_implemented`. Passage mounts `/auth/*` and `/me` itself.
- Ported on top: `Modules/Shared/Domain/{Money,LocalizedString}`, the `PaymentGateway` port in
  `Modules/Billing/Domain/Gateway/`, and `Integration/LiqPay/*`. None of it is exposed over HTTP.

## Where the old code is

Tag `v0.2.0`, also available as the local tag `firestore-final`. Browse it with
`git -C <backend> show v0.2.0:<path>` or `git -C <backend> ls-tree -r --name-only v0.2.0`.
The old `docs/migration/roadmap.md` is history at that tag only.

## Classification of the v0.2.0 code

Status key: (A) = accepted ruling, (D) = draft, (C) = contract 0.6.0 (binding as wire).
Rulings dir: `docs/requirements/rulings/` (in `show-menu-spec`).

| Area (v0.2.0 path) | Class | Reason | Spec basis |
|---|---|---|---|
| Catalog `Plan` aggregate + 8 commands (CRUD, activate/deactivate, SKU, PlanFeature) | Drop | Three fixed Plans; prices are configuration; all Plan CRUD ops removed | `2026-11-12-free-plan-and-three-plans` (A); `2026-11-13-plan-prices-trial-limits-and-dormant-values` pt 3 (A); (C) |
| Catalog `Feature`, `PlanFeature`, `FeatureQuota` | Drop | No Feature term; `SubscriptionPlan` has caps, not features | `plan-prices…` (A); (C); glossary (D) |
| Catalog `GetPlan`/`ListPlans` | Redesign later | Becomes a config-backed `listSubscriptionPlans` → `SubscriptionPlan{plan, price: Money, locationAddOnPrice, ownerLimit, itemLimit}` | (C); `plan-prices…` (A) |
| Purchases `Order`, `Invoice` | Redesign later | Spec models `payments` + `billing_documents`; the mapping of the as-built ones is explicitly open | `tech/data-model/conceptual.md:162,182`, `schema.dbml:813-835` (D); (C) `Payment` |
| Purchases `CheckoutSession`, `PurchaseSubscription`, `CheckoutInitiator`, `CancelPurchase` | Redesign later | Replaced by `createSubscriptionCheckout` (Idempotency-Key, `PaymentCheckout`) + add-on/photo-pack checkouts; no cancelPurchase | (C) |
| Purchases `PaymentGateway` port | **Ported** (adapted: `Money` minor units; monthly subscribe + one-off pay) | Gateway-agnostic port; LiqPay retained | `2026-11-13-astro-showcase-react-dashboard-and-postgresql` "LiqPay not reopened" (A); (C) `Money`; `tech/stack.md:63` (D) |
| Purchases LiqPay callback controller | Redesign later (with its use case; user chose LiqPay infra only) | Wire behaviour matches 0.6.0 (+413); target model not yet designed | (C); `state-machines/subscription.md` (D) |
| Purchases `HandleLiqPayCallbackUseCase` | Redesign later | Drives Invoice/Order/Session with Firestore paths in the app layer | (C); `schema.dbml` payments unique key (D) |
| Purchases `InvoiceStatusAuditStore` | Redesign later | Storing the raw callback is open | `schema.dbml:832-833` (D) |
| Subscriptions `Subscription` aggregate | Redesign later | active/expired/suspended keyed by account/order/plan vs trial/paid/grace_period/cancelled/lapsed/free, one per Business created at Create a Business | `2026-11-17-sign-up-creates-the-account-only` pt 2 (A); (C); `state-machines/subscription.md` (D) |
| Subscriptions invoice-paid follow-on handler | Redesign later | Spec transitions are payment-based, not Invoice-event-based | `subscription.md` (D); (C) |
| Subscriptions `CheckExpiredSubscriptionsJob` + controller | Redesign later (user chose LiqPay infra only) | Endpoint renamed `POST /v1/subscription-expiry-runs`, `schedulerOidc` only, rules from the draft state machine | (C); `stack.md:44,67`, `system-overview.md:63` (D) |
| Accounts module (Account value, Eventarc create trigger, permission docs) | Drop | Client-written docs break "Backend is the only writer"; "There is no Account object" | `astro…postgresql` pt 7 (A); `sign-up-creates-the-account-only` pts 2, 8 (A); `2026-11-16-owners-add-and-delete-businesses-at-any-time` (A) |
| Accounts `AccountMemberAbility` + voters | Redesign later | Pattern reusable; rules become Membership role/status + Lapsed lock | `astro…postgresql` pt 7 (A); (C) `MembershipRole`, `MembershipStatus` |
| IAM user lifecycle (Eventarc controller, UserCreated/Deleted handlers, onboard/remove/link-account) | Drop | Fed by the retired `auth-forwarder`; Passage + Fluent create users | `2026-11-13-passage-replaces-firebase-auth` pts 1, 3 (A) |
| IAM `User` aggregate (v0.2.0), `findUsers`, `getUser` | Drop | passage-fluent owns users; ops replaced by `getCurrentOwner`/`updateCurrentOwner` | `passage-replaces…` (A); (C) |
| IAM Ability/Voter examples | Not ported (the template's IAM already carries the same pattern) | Generic scaffolding; `Role.admin` from the PostgreSQL Product Team flag | `passage-replaces…` pt 3 (A) |
| Shared `Price` | Redesign later → `Money` (ported as a new type, decision 3) | Double + Currency struct with Node null parity vs `Money{int64, ISO}`; name collides with glossary Price (Item price) | (C) `Money`; glossary (D); `schema.dbml` numeric(10,2) (D) |
| Shared `Currency` | Drop (folded into `Money.currency`) | Only the ISO code is on the wire | (C) |
| Shared `PrefixedId` | Drop | Contract ids are `format: uuid` | (C) |
| Shared `LocalizedString` | **Ported** (adapted: `uk` required) | Matches `LocalizedText` | (C) `LocalizedText`; Menu epics (D) |
| Shared `SubscriptionDuration` | Drop | Only monthly billing is ruled | `plan-prices…` pt 3 (A) |
| Shared `JSNumber` | Drop | Firestore/Node parity only | `astro…postgresql` pt 7 (A) |
| Integration/LiqPay (gateway, envelope, transport, callback event id) | **Ported** (adapted: minor units → decimal, monthly periodicity) | Infrastructure; LiqPay retained | `astro…postgresql` (A); `stack.md:63`, `schema.dbml:824` (D) |
| Integration/LiqPay Fake / Unconfigured / Selection | **Ported** (adapted: selection keyed on `app.environment`, decision 7) | `isEmulator` was Firebase-emulator coupled | `system-overview.md:135-149` (D); (C) 503 |
| Integration/CloudRun log handler + trace middleware | Redesign later (template `TraceMiddleware` covers trace; structured Cloud Logging JSON deferred) | Hosting on Cloud Run is as-built only | `stack.md:47`, `system-overview.md:12,42` (D) |
| Integration/CloudRun `GCPAuthProvider`/`GoogleAuthProvider` | Redesign later | Consumers (Firestore, Pub/Sub, Tasks, minter) are gone; photo storage unruled | `passage-replaces…` pts 7–8 (A) |
| Integration Firestore/Firebase/Emulators/Eventarc/PubSub/CloudTasks, `cloud-functions/` | Drop | PostgreSQL + Passage | both 2026-11-13 rulings (A) |
| `Lib/` | Template wins | Near-identical; Firestore-only workarounds (tx read cache, read-before-first-write, offset billing) dropped. See "Lib drift" below | — |

Draft-dependence flags (shown to the user 2026-11-17; the user chose "LiqPay infra only" + int64
minor units): Account→Business rename (D only); the expiry job rules (D); LiqPay specifics (D);
gateway one-off `pay` (D + C); selection matrix (D); `LocalizedString` (C + D); Cloud Run hosting
(D); Money vs `numeric(10,2)` (C vs D).

## Decisions taken

1. **Base:** template `main`, taken with `git archive`, not the working tree. No Temporal; it is
   available in the template if durable workflows are needed.
2. **Scope: LiqPay infrastructure only**, plus `LocalizedString`. Everything else goes to the
   backlog below.
3. **Money** is `Money { amount: Int64 minor units, currency: ISO-4217 String }`, matching the
   contract. Conversion to LiqPay's decimal happens only in the adapter.
4. **Passage's own routes** (`/auth/*`, `/me`, mounted by `Passage.configure`, outside `/api`)
   stay: ruling point 6 has the Dashboard use Passage's JSON endpoints. They are the single
   library-owned exception to "no hand-written routes" (see `docs/conventions/WireContract.md`).
   Template sample routes (`/health`, `/version`, `/v1/items`, `/v1/users`) were removed.
5. **IAM Domain + Application + Infrastructure stay whole** (Passage needs `users`,
   `CreateUsers`, `AddUserRoles`, `GetUserQuery`; `IAMProvisioningHooks` →
   `UserCreatedIntegrationEvent` → handler → onboard is the downstream chain). Only the IAM
   Presentation (controller, route, their tests) was removed.
6. **Access levels are `public`, `authenticated`, `admin`.** `scheduler` and `eventarc` were
   dropped; 0.6.0's `schedulerOidc` needs a Google OIDC verifier and no implemented operation
   uses it. `admin` means the principal holds `Role.admin`, read from the `users` row.
7. **Passage / contract seam:** `ContractPrincipalMiddleware` binds `RequestContext.principal`
   and never rejects; `ContractAccessMiddleware` reads it and enforces the table (fails closed
   for an unlisted operation).
8. **Gateway selection** (replaces `isEmulator`): both `LIQPAY_PUBLIC_KEY` and
   `LIQPAY_PRIVATE_KEY` set → Live; else in `.development`/`.testing` → Fake (fixed sandbox test
   keypair); else Unconfigured plus a boot warning. Never Fake in `.production`.
9. **Untracked paths kept:** `.infra/triggers/`, `scripts/ci/*.py`, `.vscode/`,
   `docs/operations/deploy.md` (stripped of Firestore/Eventarc/Scheduler). Deleted:
   `scripts/dev-local.sh`, `cloud-functions/`, `.gcloudignore`.

## Redesign later (backlog)

- [ ] **`listSubscriptionPlans` from configuration.** Three fixed Plans with configured prices,
  no Plan CRUD. Serves `listSubscriptionPlans`.
- [ ] **Payment + Billing Document model replacing Order/Invoice.** The spec models `payments`
  and `billing_documents`. Serves the payment-bearing operations (`Payment` schema).
- [ ] **Subscription aggregate per the 0.6.0 status set**, created by Create a Business (one per
  Business). Statuses: trial / paid / grace_period / cancelled / lapsed / free. Serves the
  Business and subscription operations.
- [ ] **`createSubscriptionCheckout` and the other checkouts** (location add-on, photo pack) on
  the ported `PaymentGateway`. Serves `createSubscriptionCheckout` (Idempotency-Key,
  `PaymentCheckout`).
- [ ] **LiqPay callback use case + controller.** Serves `handleLiqPayCallback`, including the
  413 case. Open question: whether the raw callback payload is stored (draft `schema.dbml`
  suggests so).
- [ ] **Expiry job + `schedulerOidc` access level.** Serves `checkExpiredSubscriptions`
  (`POST /v1/subscription-expiry-runs`). Needs a Google OIDC verifier; rules come from the draft
  state machine.
- [ ] **Membership-based Business authorization** replacing `AccountMemberAbility` (Membership
  role/status + Lapsed lock). Serves every Business-scoped operation.
- [ ] **Cloud Run structured logging.** The template `TraceMiddleware` covers trace only; the
  Cloud Logging JSON handler and trace-context propagation of v0.2.0 are not ported.
- [ ] **GCP auth provider**, only if a GCP API client returns (for example photo storage).
- [ ] **Temporal**, available in the template if durable workflows are needed.
- [ ] **Passage 0.5.12 → 0.7.x.** Package.swift pins `from: "0.5.12"`; the ruling cites 0.7.x.
- [ ] **Product Team admin flag.** `Role.admin` is read from the `users` row, but nothing can
  grant it yet. Serves the `admin` access level.
- [ ] **Lib drift.** See the next section; decide whether to bring any v0.2.0 behaviour back.

### Lib drift

Compared `v0.2.0:Sources/ShowMenuBackend/Lib` with the current `Lib/`: the same 70 files exist
on both sides, so there is **no v0.2.0-only primitive file**. Differences are mostly comment
wording (Firestore terms removed), plus these functional ones:

- v0.2.0-only: `DataSourceQuery.offset`, `QueryableDataSource.countAll()`, and the filter cases
  `arrayContains` / `arrayContainsAny` (Firestore-specific; dropped with the offset-billing
  workaround).
- Template-only: `RequestContext.snapshot` / `restore(_:)` (task-locals re-bound inside the
  Fluent transaction).

## Open questions for the sponsor

- **Money vs the draft schema:** the contract has `Money` as int64 minor units; the draft
  `schema.dbml` has `numeric(10,2)`. Which wins in the Postgres schema?
- **Cloud Run as hosting:** as-built only, not ruled.
- **Postgres hosting:** undecided (affects `DATABASE_URL` wiring).
- **Photo storage:** unruled; decides whether a GCP auth provider returns.
- **Draft billing documents:** will `payments` / `billing_documents` / the subscription state
  machine be promoted to accepted? The redesign items above depend on it.

## Deferred

- Deploy wiring: `cloudbuild.yaml` does not yet pass `DATABASE_URL` or the Passage signing keys
  (`JWKS`) from Secret Manager (marked TODO in the file). Without `DATABASE_URL` the app falls
  back to in-memory SQLite, which is not acceptable in production.
- `LIQPAY_*` env wiring on Cloud Run stays as documented in `cloudbuild.yaml`; callback URL
  handling returns with the callback use case.
- Cloud-side changes (triggers, Scheduler job, IAM) were out of scope for the restart.
