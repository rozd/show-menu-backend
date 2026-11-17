# Repository Guidelines

Guidance for Claude Code / Codex / Gemini when working with code in this repository.

## Project Overview

Swift/Vapor backend for Show Menu (code name: QR menus, admin dashboard, LiqPay subscription payments) using **Domain-Driven Design (DDD)** with **CQRS** (Command Query Responsibility Segregation) over a **SQL** persistence layer, **contract-first**: the HTTP API is generated from the OpenAPI spec in `show-menu-contracts`. Aggregate storage is always a SQL database — one adapter (`Integration/Fluent/`) with two drivers behind it: **PostgreSQL** (the system of record, selected by `DATABASE_URL`) and an in-memory **SQLite** fallback so the app boots and is testable with no external services. Authentication is **Passage** (it replaces Firebase Auth). Swift 6.3 toolchain, strict concurrency (`Sendable` throughout).

This code is a restart from `vapor-standalone-template` (the old Firestore/Firebase implementation lives at tag `v0.2.0` / `firestore-final`). What was ported, dropped and still to be redesigned is in `docs/migration/restart-from-standalone-template.md` — read it before assuming a v0.2.0 feature exists. Today the contract serves `getHealth` and `getVersion`; every other operation answers `501 not_implemented`. Modules: `IAM` (users, authorization pattern), `Billing` (the `PaymentGateway` port; not exposed over HTTP yet) and `Shared` (`Money`, `LocalizedString`).

**The fallback driver is in-memory SQLite: non-durable and single-instance** — all data is lost on restart, and it does not work across multiple instances. Production requires `DATABASE_URL` (a Postgres, hosting not yet decided); no code changes with it. Why SQL only, and where a future non-SQL store would attach: **Persistence** below.

## Build & Run Commands

```bash
make build        # swift build
make run          # swift run Run serve — no prerequisites, no environment configuration
make test         # swift test
make db-up        # local Postgres (docker compose --profile postgres up -d db); make db-down stops it
make docker-build # docker compose build app

# Run a single test suite
swift test --filter UserOnboardUseCaseTests

# Run a single test by name
swift test --filter "onboard"

# Docker build (needs a read-only GitHub token for the private contracts package)
docker build --secret id=github_token,env=GITHUB_CONTRACTS_TOKEN -t show-menu-backend .
```

### Environment Variables

**None are required in development/testing** — the app starts with no configuration. **In the production environment (`serve --env production`, the Dockerfile default) the app refuses to boot** without `DATABASE_URL` (or `DATABASE_HOST`) and `JWKS`/`JWKS_FILE_PATH`: no silent fallback to in-memory SQLite or an ephemeral signing key. Optional: `PORT` (default 8080), `LOG_LEVEL`, `CORS_ALLOWED_ORIGINS` (comma-separated; unset installs no CORS middleware), `APP_ORIGIN` and `JWKS`/`JWKS_FILE_PATH` (Passage; an ephemeral dev key is generated if neither is set), and `LIQPAY_PUBLIC_KEY`/`LIQPAY_PRIVATE_KEY` (see **Billing and LiqPay**).

`configure(_:)` calls `try await configureFluentStore(app)` (`App/Fluent+Vapor.swift`), which registers the app database under `DatabaseID.app` — the composition root resolves it as the `appDatabase` dependency. It picks the **driver** from the environment — the one persistence decision the environment does make, and only because both drivers are the same adapter: `DATABASE_URL` (or `DATABASE_HOST`/`_PORT`/`_USERNAME`/`_PASSWORD`/`_NAME`) → Postgres; nothing set → an in-memory SQLite database, announced as a warning. `DATABASE_AUTO_MIGRATE` (default `true`) applies pending migrations at boot. A local database: `docker compose --profile postgres up db`.

`DatabaseID.app` is deliberately **not** Fluent's default — `appDatabase` always resolves it explicitly, so nothing depends on which database Fluent considers default. Module migrations register with `to: .app`.

## Architecture

### Request Flow

```
Generated route (contract) → Controller → CommandHandler/QueryHandler → UseCase → Repository → DataSource → Store
```

In front of the generated route, on the `/api` group: `TraceMiddleware` → `HTTPErrorMiddleware` (error envelope) → `IdempotencyKeyMiddleware` → `OptionalPassageBearerAuthenticator` → `ContractPrincipalMiddleware`, then the OpenAPI middlewares `IgnoreAcceptHeaderMiddleware` → `EmptyRequestBodyMiddleware` → `ContractAccessMiddleware` (per-operation access: public / authenticated / admin). Contract operations not implemented yet answer `501 not_implemented` (`App/ContractAPI+NotImplemented.swift`).

**Reads (Queries)** skip UnitOfWork: `Controller → QueryHandler → DataSource → Store`
**Writes (Commands)** go through UnitOfWork: `Controller → CommandHandler → UnitOfWork.execute { UseCase → Repository }` — domain events are collected during execution and dispatched after commit.

### Wire Contract (OpenAPI)

The HTTP API is **generated from the OpenAPI spec** in the private sibling package `show-menu-contracts` (SwiftPM, pinned **by tag**, product `ShowMenuContracts`; currently 0.6.0). **Hard rule: no hand-written routes** — anything exposed over HTTP is defined in the spec first (PR in `show-menu-contracts`), then the tag is bumped in `Package.swift`, then a witness is added. **The single library-owned exception** is Passage's own routes, `/auth/*` (register, login, logout, refresh, …) and `/me`, mounted by `Passage.configure` (ruling `2026-11-13-passage-replaces-firebase-auth`, point 6: the Dashboard uses Passage's JSON endpoints); they are outside `/api` and not part of the contract. Contract paths are `/v1/...` in the spec and served as `/api/v1/...` (the contract's `getCurrentOwner`, `/api/v1/me`, is not Passage's `/me`).

One `ContractAPI: APIProtocol` (`App/ContractAPI.swift`) is satisfied by witness extensions that forward to plain controllers (generated `Operations.X.Input/Output`, no Vapor `Request`). Operations in the contract but not implemented yet are stubbed in `App/ContractAPI+NotImplemented.swift`, grouped by contract tag: each throws `NotImplementedError` and answers **501 `not_implemented`**; `getHealth`/`getVersion` are in `App/ContractAPI+Health.swift`. Implementing one means moving it into its module's `Modules/<Module>/Presentation/ContractAPI+<Module>.swift` and adding it to the access table. Errors are thrown and mapped centrally by `HTTPErrorMiddleware` (error envelope). Access is one operationID-keyed table in `ContractAccessMiddleware`: `public` / `authenticated` / `admin` (`scheduler` and `eventarc` were dropped), and it **fails closed** — an unlisted operation is a 401. The table reads `RequestContext.principal`, bound earlier by the never-rejecting `ContractPrincipalMiddleware`.

Resolving the package needs a read-only GitHub token: CI secret `SHOWMENU_WORKSPACE_TOKEN`; Docker build secret `github_token`; Cloud Build secret `github-contracts-token`. Full rules: `docs/conventions/WireContract.md`.

### Dependency Injection

Dependencies are declared on the `Application.Dependencies` protocol in `App/Vapor+Dependencies.swift` and wired via `CompositionRoot`. Shared infrastructure (transport, the active `store` + its `directTransaction`, the DDD dispatchers and `unitOfWork`) lives in `Vapor+Dependencies.swift`; each module's factories live in a `Modules/<Module>/CompositionRoot+<Module>.swift` extension on `CompositionRoot`. Access from anywhere via `app.deps`. The `Resolver` caches instances by keypath and supports overrides for testing via `Partial<Dependencies>`. The contract is central, the resolutions are federated — the rule, the core/module split table and the file shape are in `docs/conventions/CompositionRoot.md`.

**Factory pattern**: Repositories and UseCases are created per-request via factory closures (`RepositoryFactory`, `UseCaseFactory`) that receive a `UnitOfWorkContext` — this passes the transaction and domain event collector into each operation.

### Module Structure (DDD Layers)

Each business module in `Modules/` follows this layering:

- **Domain** — `Entity/` (AggregateRoot), `Event/`, `Error/`, `Repository/` protocol, `Operation/` (cross-aggregate logic, see below), `Specification/` (actor-free domain-state rules). Pure business logic, no infrastructure imports.
- **Application** — `Command/` + `Query/` (CQRS), `UseCase/`, `DTO/`, `Mapper/`, `DataSource/` protocol, `Authorization/` (principal-aware `*Ability` + `Voter/`). Orchestration layer.
- **Infrastructure** — `Model/` (store `Codable` models), `DataSource/` impl, `Repository/` impl. The only store-specific layer.
- **Presentation** — controllers and contract witnesses. HTTP routes are generated from the OpenAPI contract in `show-menu-contracts` (contract-first, no hand-written routes; the only other routes are Passage's own `/auth/*` and `/me`; see `docs/conventions/WireContract.md`).

### Key Patterns

- **Domain events** ride the `DomainEventRecorder` → `DomainEventCollector` pipeline (collected during UnitOfWork execution, **dispatched after commit**). Two kinds with different owners — *lifecycle* (Repository) vs *semantic* (AggregateRoot); see **Domain Events: Lifecycle vs Semantic** below.
- **Mapper** protocol has three conversion directions: `toEntity(model:)`, `toModel(entity:)`, `toDTO(entity:)`.
- **DataSource** vs **Repository**: DataSource is a raw CRUD interface (insert, update, delete, fetch) over store models, executed through the store's transaction handle (`FluentTransaction` — a transport-erased wrapper over an active transaction, or `.direct(database:)` for non-transactional reads). Repository is the domain-level abstraction that works with entities, holds a `context: any UnitOfWorkContext`, resolves its DataSource via `dataSourceFactory("", context.transaction)`, and records **lifecycle** events (`created`/`updated`/`deleted`) on each `insert`/`update`/`delete`. It is store-agnostic — it names no adapter type. QueryHandlers get the `directTransaction`; writes run inside the adapter's `UnitOfWork`, which threads the live transaction through `context.transaction`.
- **QueryableDataSource** adds filtered/ordered query support with `DataSourceQuery`, `DataSourceFilter`, `DataSourceOrder` — deliberately narrow (equality/comparison/`in`, ordering, limit), carrying only what a binding can push down so a filter never silently degrades into an unfiltered read.
- **Plain-SQL reads** cover everything the DSL cannot express — search, `OFFSET`, a total alongside a page, joins, aggregates. The module declares a narrow read port in `Application/DataSource/` and binds it in `Infrastructure/` with a hand-written statement over `transaction.sql`; Writes never take this path — they stay on Repository → `DataSource`. Dialect policy is **portable-first**: stay in the SQLite ∩ Postgres subset unless a query genuinely needs more, and cover anything Postgres-specific in the `POSTGRES_TEST_URL`-gated suite.
- **Optimistic concurrency** rides an opaque `Version` token carried by every `AggregateRoot`; writes are check-and-set and conflicts surface as `ConcurrencyError`. See **Optimistic Concurrency (Versioning)** below.
- **Transactional Outbox** makes integration-event delivery reliable: a use case records the event into a durable outbox **inside the command's transaction** (`context.outbox.record(_:)`) instead of publishing post-commit; a relay drains the outbox and publishes through the existing `IntegrationEventChannel`. Closes the commit-then-publish dual-write gap. See **Transactional Outbox (Reliable Integration Events)** below.
- **RetryPolicy** (`Lib/AOP/Resilience/`) wraps a transient-failure-prone outbound async call in bounded retries with capped exponential backoff: `try await policy.execute { … }`. Its nested pure schedule, `RetryPolicy.Backoff`, is reused by the outbox relay for cross-pass backoff. `CircuitBreaker` (same folder) adds closed→open→half-open fast-fail protection for outbound dependencies, and `RateLimiter` (same folder) paces calls to a quota-bound one (`RateLimiter(.perMinute(600))`) — its slots are *reserved* before the actor suspends, because the "time since the last call" form races under actor reentrancy. See **Resilience (Retry / Circuit Breaker / Rate Limiter)** below.
- **Operation** (Domain-layer convention, exactly like `Policy` — NOT a protocol/base class, nothing under `Lib/`) is stateless, pure logic coordinating 2+ AggregateRoots. Lives in `Modules/<Module>/Domain/Operation/`, named for the activity with no suffix (`TransferFunds`, not `TransferFundsOperation`), as a caseless `enum` with one static pure entry point. No Repository/async/I/O; throws domain errors only; composes Policy/Specification. The UseCase stays pure orchestration: load aggregates → call the Operation → persist. See `docs/conventions/Operation.md`.

### Domain Events: Lifecycle vs Semantic

Two kinds of domain event share one pipeline (`DomainEventRecorder` → `DomainEventCollector`, collected during UnitOfWork execution and **dispatched after commit**) but have **different owners**:

- **Lifecycle events** (`created` / `updated` / `deleted`) are *infrastructure/audit facts*, owned by the **Repository**. Its `insert` / `update` / `delete` extension methods record them automatically (insert `prepend`s `.created`; update/delete append) — bound to the *actual persistence operation* and dispatched only if the transaction commits. **Never manually record `.created/.updated/.deleted` in a UseCase or aggregate** — the Repository already does, so a manual call double-emits.
- **Semantic events** (`UserOnboarded`, `EmailChanged`, `AccountClosed`, …) are *domain facts the business cares about*, owned by the **AggregateRoot**. Raise them with `record(event:)` **inside the aggregate's behavior method**, at the moment of the state transition — they carry payload/meaning, and only the aggregate knows the invariant held. They coexist with lifecycle events in the same recorder.

Why this split: classic DDD reserves *domain events* for business-significant occurrences raised by the aggregate; generic CRUD `created/updated/deleted` are not domain events but an infrastructure/audit concern, so they live in the Repository — keeping that concern out of the domain model.

**Events are facts, not commands.** A `DomainEventHandler` reacts to a *committed* event with **follow-on work in _other_ aggregates** (eventual consistency / sagas) — never to perform the originating aggregate's own persistence. A UseCase orchestrates its own aggregate's write **explicitly** (`load → mutate → repository.insert/update/delete`); it does not raise an event to *trigger* that write. A handler may scope to a single kind via `static var kind` (defaults to `nil` = all kinds).

### Transactional Outbox (Reliable Integration Events)

**Cross-process *integration* events** (not in-process domain events) are delivered reliably via the **Transactional Outbox**. Publishing an integration event *after* the command's transaction commits is a dual-write: a crash between commit and publish loses the event. The outbox closes that gap.

- **What goes in the outbox: the INTEGRATION event** (approach *a*, not the domain event). Integration events already have a transport-ready serialization (`IntegrationEventEnvelope` = kind + metadata + JSON payload, via `IntegrationEventCoder`/`IntegrationEventRegistry`), so an outbox row stores an envelope and the relay republishes it with **zero domain knowledge**. The trade-off: the decision of *which* integration event to emit is made **inside the transaction** — the use case records it explicitly, consistent with "a UseCase orchestrates its own writes explicitly."
- **Recording (write side).** `UnitOfWorkContext.outbox` is an `OutboxIntegrationEventChannel` (symmetric to `collector`). A use case calls `try await context.outbox.record(event)` after persisting its aggregate. This writes an `OutboxMessage` through an `OutboxStore` **bound to the same `context.transaction`** as the Repository — so the row is buffered into that transaction and commits atomically with the state change, or rolls back with it. `record` **throws** (deliberately *not* the fire-and-forget `IntegrationEventChannel.publish`): an outbox-write failure must abort the transaction.
- **Relay (publish side).** `OutboxRelay.drain()` fetches pending+due rows in best-effort FIFO order (`createdAt`, then per-transaction `sequence`), publishes each **through the existing `IntegrationEventChannel`**, marks it `published`, and prunes published rows past a retention TTL. Failures are retried with bounded exponential backoff (`RetryPolicy.Backoff`); the row stays `pending`. Shipped as `OutboxRelayJob` (a Vapor `AsyncScheduledJob`); wire it with `try app.startOutboxRelay()` (`App/Outbox+Vapor.swift`) — **opt-in**, like the other queue building blocks.
- **Delivery is at-least-once.** A crash after publish but before `markPublished` republishes on the next drain; **consumers must dedup** (the **Inbox** is the consumer-side half — see **Inbox (idempotent consumer)** below). Note: since `IntegrationEventChannel.publish` is fire-and-forget, end-to-end delivery is "durably recorded and handed to the channel at least once" — the channel owns its own transport durability.
- **Placement.** Primitives in `Lib/DDD/Outbox/` (`Outbox` facade, `OutboxStore`, `OutboxMessage`, `OutboxIntegrationEventChannel`, `OutboxRelay`); the store binding in `Integration/Fluent/FluentOutboxStore.swift` (a real `outbox` table with indexed `status`/`available_at`/`published_at`, so the relay's drain is an index scan rather than a full read); relay job in `Integration/Vapor/OutboxRelayJob.swift`; wiring in `App/Outbox+Vapor.swift`. Polling is the portable default relay; a store that emits change events (a change stream / CDC trigger on outbox-row creation) or an external scheduler hitting an endpoint are lower-latency alternatives that drive the same `drain()`.

> **Durability caveat with the default driver:** the outbox is only as durable as the database behind it. On in-memory SQLite, unpublished rows die with the process — the *atomicity* guarantee (row and state change commit together) holds, the *durability* one does not. Both hold on Postgres, which is when the pattern actually earns its keep.

### Optimistic Concurrency (Versioning)

Every write is an **optimistic check-and-set** keyed on an abstract per-aggregate concurrency token.

- **`Version`** (`Lib/DDD/Concurrency/Version.swift`) is an **opaque** token carried by every `AggregateRoot` (`var version: Version`). The domain never inspects or hand-increments it — it is loaded with the aggregate, carried back on write, and advanced by the persistence layer. `.none` means "not yet persisted"; two `.none` tokens compare equal.
- **`ConcurrencyError`** (`Lib/DDD/Error/ConcurrencyError.swift`) — `.versionConflict(entity:id:expected:actual:)`, raised when the stored token no longer matches the loaded token.
- **Store binding:** the token is bound to a monotonic integer `version` field on the document (`VersionedModel { var version: Int? }`, in `Lib/DDD/Concurrency/VersionedModel.swift`), and the adapter realizes check-and-set as a single conditional statement — `UPDATE … SET …, version = $next WHERE id = $id AND version = $expected RETURNING id` — so there is no window at all; `RETURNING` is what makes a zero-row (conflicting) update *detectable*, since Fluent's `QueryBuilder.update()` returns `Void` and would otherwise report a lost update as success. *Why an explicit field rather than a store-native write token (`updateTime`/etag/`xmin`):* not every store exposes one on reads or accepts it as a write precondition, so an explicit integer field is the portable lowest common denominator — bound here to a `version` column, and equally bindable to `xmin`.
- **Ownership / flow:** the concrete **Repository** owns the token lifecycle — `doInsert` establishes the initial token, `doUpdate`/`doDelete` call the DataSource's `update(model:ifMatching:)` / `delete(byId:ifMatching:)` and advance the in-process token. The `DataSource` protocol carries those CAS methods with **default no-op implementations**, so only versioned stores opt in.
- **Conflict propagation:** the `UnitOfWork` surfaces `ConcurrencyError` **unchanged** through the CommandHandler — never collapses it into a generic store error. Map it at the edge to `409 Conflict` (internal stale write) or `412 Precondition Failed` (stale `If-Match`).
- **No data migration:** an absent `version` field decodes to `nil` (`.none`) and matches a `.none` expected token, so existing documents adopt versioning on their first write.

**ETag at the edge (optional, separable):** `Integration/Vapor/ETag+Vapor.swift` provides reusable glue — `Version.etag`, `Request.ifMatch`, `Response.setETag`. Responses advertise the current version as an `ETag`; mutating endpoints read `If-Match`, reject a stale edit early with `412` (a fast pre-check before the transaction), and thread the precondition into the command where the in-transaction CAS is authoritative. Currently unwired; wire it when a contract operation needs it. Creates don't need `If-Match`.

### Authentication

**Passage** is wired as the authentication layer, operating in **overlay mode S1** (a single `users` table with two Fluent lenses).

**Architecture & responsibility split:**
- **Passage** (`Integration/Passage/`) owns **authentication** — credentials, token issuance/refresh, the `/auth/*` routes, identity verification. Credentials never enter the domain.
- **IAM** (`Modules/IAM/`) is the system of record for the business-side `User` aggregate and **all authorization** (`Ability`/`Voter`), regardless of which authentication provider answers *who* the caller is.

**Single-table design:** The shared `users` table has two Fluent lenses —
- Passage's lens (`PassageUserRecord`) declares `password_hash` — the only Passage-exclusive column — plus the identity columns it writes: `email`, `phone`, `username`, `email_verified`, `phone_verified`.
- IAM's lens (`UserModel`) declares everything **except** `password_hash`: the identity columns above (carried on the `User` aggregate) plus `display_name`, `photo_url`, `disabled`, `roles`, `version`.

FluentKit's INSERT/UPDATE touch only declared fields, so `password_hash` is structurally out of IAM's reach — credential material never enters the aggregate/DTO/mapper. The identity columns are shared: Passage writes them on registration and identifier verification; IAM's only write path onto an existing row (the onboarding upsert) early-returns, so a future IAM update use case must carry them through rather than dropping them (see the column-isolation test).

**Integration seams:**
- `IAMProvisioningHooks` — Passage account registration publishes `UserCreatedIntegrationEvent`, triggering IAM onboarding (idempotent; the row already exists via `PassageUserRecord.passageMakeUser`).
- `ContractPrincipalMiddleware` (+ `PassagePrincipalResolver`) — bearer token → `RequestContext.principal` for downstream `Ability`/`Voter` checks. Resolves `User` through IAM's query handler on every request, so role changes take effect immediately. Never rejects; `ContractAccessMiddleware` decides per operation.

**Wiring:** `configurePassage` mounts `/auth/*` and `/me` itself; the contract routes use `OptionalPassageBearerAuthenticator` (Passage's `PassageBearerAuthenticator` throws on a garbage token, so failures are swallowed) + `ContractPrincipalMiddleware`, and `ContractAccessMiddleware` enforces the access table (no `PassageGuard`). See `App/Passage+Vapor.swift` for configuration (env: `APP_ORIGIN`, `JWKS`/`JWKS_FILE_PATH`; ephemeral dev key if neither is set).

**Removing authentication:** delete `configurePassage` call + middleware group + `Integration/Passage/` + `Modules/IAM/IAM+Passage.swift`, and add an alternative principal middleware before PEPs run.

### Authorization (Ability / Voter)

Authorization primitives live in `Lib/AOP/Authorization/`. `Lib/AOP/` groups **cross-cutting concerns** (authorization, idempotency, resilience) under the `AOP` acronym for symmetry with the other `Lib` areas (`DDD`, `CQRS`, `FSM`) — it is **not** an AOP framework (no aspects/pointcuts/weaving), just primitives whose concern is cross-cutting rather than DDD/CQRS-tactical:

- **`Ability`** — the named entry point for *one* authorization decision (one action). Principal-aware: `evaluate(principal:subject:) -> Decision`. The action is encoded by the type, so suffix concrete types `*Ability`. **Call sites only ever talk to Abilities, never to Voters directly.**
- **`Voter`** — a small, reusable unit returning a `Vote` (`allow` / `deny(reason:)` / `abstain`) over `(principal, subject)`. Voters are the composition mechanism *underneath* an Ability; suffix `*Voter`. Type-erase with `AnyVoter<Subject>` to aggregate them.
- **`Decision`** — `allowed` / `denied(reason:)`; never a bare `Bool` (a denial must carry a reason for error messages/audit).
- **`VoteAggregationStrategy`** — reduces `[Vote] -> Decision`. Default `DenyOverridesStrategy` (`.denyOverrides`): any `deny` wins, else any `allow` wins, else **default deny**. `VotingAbility<Subject>` wraps voters + strategy.
- **`Principal`** — minimal security identity (`id`, `roles: Set<Role>`). `Lib` defines the `Role` type; concrete role values (e.g. `.admin`) live in the module that checks them. Security identity stays here / in Application, **never in the domain model**.

**Ability vs. Policy**: the presence of a principal/actor distinguishes an `Ability` (principal-aware authorization, Application layer) from a business `Policy` (actor-free domain logic, `*Policy` static functions in Domain). When an authZ rule depends on **domain state** (ownership, status, …), express that part as a domain `Specification` and have the Voter/Ability **compose** it (see `SelfRemovalVoter` composing `AccountSelfRemovableSpecification`).

**Placement & naming**:
- `Modules/<Module>/Application/Authorization/<Action>Ability.swift`
- `Modules/<Module>/Application/Authorization/Voter/<Name>Voter.swift`
- `Modules/<Module>/Domain/Specification/<Name>Specification.swift` (domain-state checks)

**Enforcement (PEP)**: the **UseCase is the Policy Enforcement Point**. After loading the aggregate(s) and *before any mutation*, invoke the Ability and `throw AuthorizationError` on a `denied` Decision. The Ability is injected through the use-case factory (like `mapper`/`repositoryFactory`). The **principal comes from `RequestContext.principal`** (`@TaskLocal`); PEPs **fail closed** (`throw AuthorizationError.missingPrincipal`) when it is unset. Set it at a request/message boundary with `RequestContext.$principal.withValue(_:) { … }` — e.g. `UserDeletedIntegrationEventHandler` runs as `SystemPrincipal` (a trusted internal actor holding `.admin`) so platform-initiated flows pass through the normal rules rather than bypassing them. Worked example: `RemoveUserAbility` (in IAM) composes `AdminRoleVoter` + `SelfRemovalVoter`, enforced in `UserRemoveUseCase`.

### Idempotency (inbound command de-duplication)

A second cross-cutting concern under `Lib/AOP/` — `Lib/AOP/Idempotency/`. It de-duplicates *retried* inbound commands keyed on the client's `Idempotency-Key` HTTP header, so a retry replays the first response instead of re-running the work.

- **`IdempotencyKey`** — validated value type carried as request *metadata* (the `Idempotency-Key` header), **never** a field on a command DTO. Extracted at the edge by `IdempotencyKeyMiddleware` (`Integration/Vapor/IdempotencyKey+Request.swift`) into `RequestContext.idempotencyKey` (`@TaskLocal`), exactly like `traceId`/`principal`.
- **`RequestFingerprint`** — SHA-256 over the canonical (sorted-key) JSON of the command payload. Stored on the record so a key reused with a *different* body is rejected (`fingerprintMismatch`) rather than silently replaying the wrong response.
- **`IdempotentCommandHandler`** — a **protocol mixin** refining `CommandHandler`: a handler **opts in by conforming**, and gains an idempotent `handle` via a default implementation. That default wraps the handler's own `perform(_:in:)` so reserve / replay / store run **inside the command's single transaction** (see atomicity below). No struct decorator and no type erasure — the concrete handler type is preserved end-to-end.
- **`IdempotencyStore`** — split into a **read phase** (`reserve` → probe) and a **write phase** (`complete` → persist). Two reasons: the de-duplication record must enlist in the command's *own* transaction, and many document stores forbid reads after writes within a transaction — so the probe has to happen before the work writes anything. `FluentIdempotencyStore` binds it with the table's **primary key** as the unique guard: `reserve` probes the row *before* the work writes; `complete` is the *last* write, and a losing duplicate `INSERT` violates the key and aborts that transaction. SQL does not need the read-before-write ordering, but the binding keeps it so the port stays satisfiable on the strictest store. Records carry a TTL `expiresAt` (friendly to stores with native TTL policies); an expired probe is treated as empty.

**Protocol (reserve → run → store / replay):** new key → run the handler's `perform`, then store the response; *completed* duplicate → **replay** the stored response, never re-execute; *in-progress* duplicate → reject (`requestInProgress` → 409); *fingerprint differs* → reject (`fingerprintMismatch` → 422). Edge status mapping is `IdempotencyError: AbortError` in the Vapor layer.

**Atomicity (critical):** the de-duplication record and the command's writes commit in the **same** `UnitOfWork` transaction — a crash can't leave "marked-but-not-done" or "done-but-not-marked". This is achieved by the `CommandHandler` `perform(_:in:)` / `handle` split (mirrors `Repository.doInsert`/`insert`): `IdempotentCommandHandler`'s default `handle` opens one `unitOfWork.execute` and composes reserve/work/store around the conforming type's `perform` inside it — never a wrapper that opens its own connection.

**Defaults (configurable via `IdempotencyConfiguration`):** key scope `actorAndCommandType` (principal id + command type + key, hashed to the doc id); in-flight strategy `rejectConflict` (409, client retries — in practice the transaction runner's retry usually upgrades a concurrent duplicate to a clean replay); TTL 24h. Currently unwired (no contract operation uses it yet); the IAM user-lifecycle command handlers do **not** conform — they're driven by integration events and conform to `InboxedCommandHandler` instead, de-duplicating by event id (see **Inbox (idempotent consumer)** below).

### Inbox (idempotent consumer)

The consumer-side half of the reliable-messaging story — `Lib/DDD/Inbox/`, symmetric with `Lib/DDD/Outbox/`. The outbox makes delivery **at-least-once**; the inbox makes *processing* effectively-once by de-duplicating redelivered integration events per consumer, keyed on the event id every `IntegrationEvent` already carries (`id: UUID`, preserved through `IntegrationEventEnvelope` and `OutboxMessage`).

- **`RequestContext.integrationEventId`** (`@TaskLocal`) — bound by the integration-event **dispatcher** around every handler invocation (the message-boundary analogue of the HTTP edge binding `idempotencyKey`), so both delivery paths — the in-process channel and the Vapor Queues job — carry it, and event handlers need no propagation code.
- **`InboxedCommandHandler`** — a protocol mixin refining `CommandHandler where Result == Void`: inbox consumers are fire-and-forget effects, so there is no stored response to replay and a duplicate is skipped **silently** (success, not an error). Same shape as `IdempotentCommandHandler`: the default `handle` opens one `unitOfWork.execute` and composes reserve → the conforming type's `perform` → complete inside it; with no bound event id (e.g. direct invocation) it is a transparent pass-through. The `Void` constraint also means no handler can conform to both mixins — `IdempotentCommandHandler` requires `Result: Codable`.
- **`InboxStore`** — the same read-phase (`reserve`) / write-phase (`complete`) split as `IdempotencyStore`, for the same reason: the marker must enlist in the command's own transaction, and the probe must precede any transactional write. Only two outcomes: `proceed(ticket)` / `alreadyProcessed`. The record id is SHA-256 over (consumer command type + event id), so two consumers of one event each process it exactly once. Binding: `FluentInboxStore` (the `inbox` table's **primary key**; a losing duplicate `INSERT` aborts that transaction as `InboxError.duplicateEvent`).
- **Atomicity / crash behaviour:** marker and work commit in the **same** transaction — a crash mid-processing rolls both back and the redelivery reprocesses cleanly. A *concurrent* duplicate races: both probe an empty slot, the loser's whole transaction aborts on the marker's uniqueness guard, and the dispatcher logs-and-swallows the error — correct, because the winner committed the work (and deliberately no queue retry for the loser).
- **Retention:** records carry `expiresAt` (TTL via `InboxConfiguration`, default 7 days — a marker only needs to outlive the redelivery window; matches the outbox retention); an expired probe is treated as an empty slot.
- **Worked example:** the IAM user-lifecycle command handlers (`CreateUserAccountCommandHandler`, `DeleteUserAccountCommandHandler`). `UserOnboardUseCase` keeps its existence check on top — lazy provisioning mints a *fresh* event id per publish, which same-event-id dedup by design cannot catch.

### Resilience (Retry / Circuit Breaker / Rate Limiter)

`Lib/AOP/Resilience/` — the third cross-cutting concern under `Lib/AOP/`: fault handling around outbound calls. `RetryPolicy.swift` has two composable pieces:

- **`RetryPolicy.Backoff`** — a *pure* backoff schedule: capped exponential growth (`initial`, `multiplier`, `cap`). `delay(forAttempt: n)` is the wait after the n-th failure (`initial × multiplier^(n−1)`, capped). Build with `.exponential(initial:multiplier:cap:)`; use `.immediate` (all zeros) in tests. Pure math — assert on `delay(forAttempt:)` directly, no sleeping.
- **`RetryPolicy`** — in-process bounded retries: `maxAttempts` (total attempts, ≥ 1; `1` means no retry), a `Backoff`, and a `shouldRetry: (any Error) -> Bool` predicate (default: retry everything). `execute` runs the operation, sleeps per the schedule between attempts, and rethrows the *last* error when attempts are exhausted or the predicate declines. **Cancellation is never retried** — a thrown `CancellationError` propagates immediately, and the inter-attempt sleep is cancellation-transparent (no `try?` swallowing).

```swift
let policy = RetryPolicy(
    maxAttempts: 3,
    backoff: .exponential(initial: 1, multiplier: 2, cap: 30),
    shouldRetry: { ($0 as? MyTransportError)?.isTransient ?? false }
)
let doc = try await policy.execute { try await dataSource.fetch(byId: id) }
```

A named preset for a specific transport (e.g. a `RetryPolicy` retrying only a store's connection-closed errors) is a **binding, not `Lib` code** — define it as a `RetryPolicy` extension under `Integration/<Store>/`. None ships here: what counts as retryable (`DatabaseError.isConnectionClosed`, serialization failures) is the project's call. Usage rules:

- **Where it belongs:** around *outbound* infrastructure calls (a real store's reads, third-party HTTP APIs, a queue transport) in the Integration layer — not in UseCases/domain logic, and not around a whole `UnitOfWork` (a store's transaction runner usually retries contention itself; stacking another retry there multiplies work).
- **Retry only transient failures** — pass a `shouldRetry` matched to the transport's error taxonomy. Blind retries of non-idempotent writes on ambiguous failures can duplicate work; pair with the Idempotency/Outbox machinery where that matters.
- The **outbox relay does not use `RetryPolicy.execute`** — its retries span drain passes with per-row persisted attempt counts, so it reuses only the schedule: `Outbox.backoff: RetryPolicy.Backoff` computes each failed row's next `availableAt`.

**`CircuitBreaker`** (`Lib/AOP/Resilience/CircuitBreaker.swift`) — an `actor` giving an outbound dependency closed→open→half-open fast-fail protection: it trips after `failureThreshold` consecutive failures, fast-fails during the cooldown with `CircuitBreakerOpenError` (failure count + last error + `retryAfter`), then admits exactly **one** half-open probe (success closes the circuit, failure reopens it; concurrent callers fast-fail while the probe is in flight). Timing runs on an injectable `now` clock for deterministic tests. Unwired building block — wrap outbound calls where needed. Composing with retry: put the retry outermost (`policy.execute { try await breaker.execute { … } }`) and have `shouldRetry` exclude `CircuitBreakerOpenError`, so every attempt consults the breaker and an open circuit fails fast instead of being hammered.

**`RateLimiter`** (`Lib/AOP/Resilience/RateLimiter.swift`) — an `actor` pacing **outbound** calls so a quota-bound dependency is never hammered. `RateLimit` states the vendor's *published* quota — `.perSecond(10)`, `.perMinute(600)`, or `.every(.milliseconds(70))` for the literal minimum-spacing form — and derives `spacing = period / count`. There is **deliberately no default limit**: the right number comes from the dependency's docs, and a baked-in default is just one vendor's number in disguise. Use `execute`, or `acquire()` as the primitive where `execute` doesn't fit:

```swift
let limiter = RateLimiter(.perMinute(600))                                   // composition root
let page = try await limiter.execute { try await vendor.fetchPage(cursor) }  // call site
```

**Reservation, not "time since the last call"** — the load-bearing invariant. `acquire()` reserves the next free slot and sleeps until *its own* slot falls due, and the reservation is written **before the method ever suspends**, which makes it atomic with respect to the actor. **Never** rewrite it as "if `now - lastCall < spacing`, sleep the difference": actors are **reentrant**, so the `await` on the sleep releases the actor, every concurrent caller reads the same stale `lastCall`, and they all wake together — enforcing the limit only for strictly serial callers, i.e. the one case that needed no limiter. `RateLimiterTests` pins this: 4 concurrent acquisitions at 50 ms spacing must take ≥ 150 ms (the reentrant form finishes in ~55 ms).

Guarantees and limits:

- **Smooth spacing, no burst** — successive acquisitions are ≥ `period / count` apart, so the vendor's window is never exceeded. Unlike a token bucket, an idle limiter banks no credit; that is the deliberate conservative choice.
- **Bounds the rate of *starts*, not concurrency** — `execute` is `nonisolated`, so the operation runs outside the actor and slow calls overlap freely. Add a bounded task group or semaphore if you also need a concurrency cap.
- **Per-process and in-memory** — every app instance gets its own limiter. Size the limit per instance (vendor quota ÷ max instances), or use a distributed limiter when a single global quota must hold.
- **Cancellation propagates** — a caller cancelled while waiting throws `CancellationError` and does not run its operation. Its reserved slot is abandoned rather than reclaimed, which can only make pacing more conservative.
- **No injectable clock**, unlike `CircuitBreaker` — that one only *reads* time, so a `now` closure fully determinizes it; a limiter must actually sleep. Its tests use small real durations and assert **lower bounds only** (`Task.sleep` never returns early, so lower bounds are stable under CI noise; an upper bound on a sleep would be flaky).

Unwired building block. Composing the trio: retry outermost, limiter **innermost** so every retried attempt is paced — `policy.execute { try await breaker.execute { try await limiter.execute { … } } }`.

### Billing and LiqPay

`Modules/Billing/Domain/Gateway/` holds the provider-agnostic `PaymentGateway` port (`checkout` → hosted payment page URL, `status`, `decodeCallback`; provider-agnostic `PaymentStatus` and `PaymentGatewayError`). Amounts are `Money` (`Modules/Shared/Domain/Money.swift`: `Int64` minor units + ISO-4217 code, matching the contract); the LiqPay adapter converts to LiqPay's decimal string. `Integration/LiqPay/` holds the adapters: `LiqPayPaymentGateway` (signs the checkout envelope; `subscribe` with `month` periodicity or one-off `pay`), `LiqPayCheckoutTransport`, `FakePaymentGateway`, `UnconfiguredPaymentGateway` and `LiqPayGatewaySelection`, built on the `RetryPolicy` + `CircuitBreaker` composition from `Lib/AOP/Resilience`. **Selection** is keyed on `app.environment`: both `LIQPAY_PUBLIC_KEY` and `LIQPAY_PRIVATE_KEY` set → Live; otherwise `.development`/`.testing` → Fake (fixed sandbox test keypair); otherwise Unconfigured (every call throws `notConfigured`) plus a boot warning — never Fake in production. The gateway is a `paymentGateway` dependency (`Modules/Billing/CompositionRoot+Billing.swift`) and is **not exposed over HTTP**: the Payment/Billing Document model, checkouts, the LiqPay callback and the expiry job are the redesign backlog in `docs/migration/restart-from-standalone-template.md`. Never log the keys.

### Integration Layer (`Integration/`)

Everything store- or framework-specific lives here. `Lib/` never imports from it.

- **Fluent/** — the persistence adapter, over SQLite or Postgres (its own `README.md` has the details, including the read-side DSL/plain-SQL split and the dialect policy). Wired by `configureFluentStore(app)` in `configure(_:)`.
  - `FluentTransaction` — the transport-erased handle: `.transaction(database:)` wraps the connection Fluent opened for a command (statements enlist automatically — no write buffer, because Postgres has a real transaction), `.direct(database:)` is for QueryHandlers and the relay. Also vends the `SQLDatabase` beneath the Fluent handle.
  - `FluentDataSource` (+`Query`, +`Concurrency`) — the CRUD/query/check-and-set binding. **Binds at the SQL layer, not through Fluent's ORM**: `DataSource<Model>` is generic over an opaque `Codable` model while a `FluentKit.Model` is a bespoke class per table, so `SQLQueryEncoder`/`SQLRowDecoder` let the store model *be* the row and a module's data source stays four lines (`transaction`, `table`, `logger`, `documentId(for:)`). Filters/orders/limits are pushed down into SQL; a dotted path throws `FluentQueryError` rather than degrading to an unfiltered read.
  - `FluentUnitOfWork` — `database.transaction { … }`; domain events dispatched after commit; `ConcurrencyError` surfaced unchanged. Also **re-binds `RequestContext` inside the transaction**: FluentKit runs the closure in a `Task` started on the event loop, which inherits no task-locals, so without `RequestContext.snapshot`/`restore(_:)` a command would run with no principal (PEPs fail closed) and no idempotency key or event id (de-duplication silently off).
  - `FluentOutboxStore` / `FluentIdempotencyStore` / `FluentInboxStore` — these three *do* use Fluent's ORM (`OutboxMessageRecord`, `IdempotencyKeyRecord`, `InboxMessageRecord`), because their schemas are fixed and the typed query builder reads better. The idempotency and inbox tables' **primary key is the in-flight guard**: a duplicate `INSERT` violates it and aborts the transaction. Note a Fluent model's table name is static, so `Outbox.collection` must equal `OutboxMessageRecord.schema` — `configureFluentStore` fails at startup otherwise.
  - `FluentCoding` — the row-coding boundary: camelCase coding keys → `snake_case` columns, `nil` encoded as explicit `NULL` (an update must clear a column, not leave it stale), and the same transform applied to query field names. Avoid acronym runs in coding keys (`photoUrl`, not `photoURL`).
  - `FluentStoreError` / `FluentQueryError` — store-level failures and refused queries. Concurrency conflicts are *not* store errors.
  - `Migration/` — the adapter's own tables (`outbox`, `idempotency_keys`, `inbox`). Module tables live in `Modules/<Module>/Infrastructure/Migration/` and are registered in `App/Fluent+Vapor.swift`.
- **Passage/** — authentication framework bindings (overlay mode S1):
  - `PassageUserRecord` — Fluent model conforming to `PassageUserModel`, the second lens on the shared `users` table. Exposes Passage-owned columns only; declares no IAM-owned fields.
  - `Migration/AddUserAuthColumns.swift` — migration adding Passage's credential column (`password_hash`) to the shared `users` table; the identity columns (`phone`, `username`, `phone_verified`) live in IAM's `CreateUsers`.
  - `PassagePrincipal` — security identity carrying authenticated Passage user's id and IAM-resolved roles.
  - `PassagePrincipalResolver` — Passage user → `PassagePrincipal`, resolving roles through IAM's `User` query handler.
  - `ContractPrincipalMiddleware` / `OptionalPassageBearerAuthenticator` — the lenient (never-rejecting) bearer + principal binding for contract routes.
  - Wired by `configurePassage(_:)` in `configure(_:)`, which registers Passage migrations onto `DatabaseID.app` and configures the Passage framework (see env: `APP_ORIGIN`, `JWKS`/`JWKS_FILE_PATH`).
- **Vapor/** — framework glue, independent of the store:
  - `TraceMiddleware` — reads `X-Request-ID` (falling back to `X-Correlation-ID`) or generates one, and populates `RequestContext.traceId` so every log line and downstream command/event correlates to one request. Installed at the very beginning of the middleware chain in `entrypoint.swift`.
  - `ContractAccessMiddleware` — the operationID → `Access` table (public / authenticated / admin; fails closed); `IgnoreAcceptHeaderMiddleware`, `EmptyRequestBodyMiddleware`; `HTTPErrorMiddleware` (`useErrorEnvelope()`, `HTTPErrorMapping`, `NotImplementedError`).
  - `ETag+Vapor` — the optional ETag/If-Match edge layer (`Version.etag`, `Request.ifMatch`, `Response.setETag`).
  - `IdempotencyKey+Request` — `IdempotencyKeyMiddleware`, lifting the `Idempotency-Key` header into `RequestContext`.
  - `OutboxRelayJob` — the `AsyncScheduledJob` that drains the transactional outbox; scheduled by `App/Outbox+Vapor.swift`.
  - `VaporQueueIntegrationEventChannel` — an `IntegrationEventChannel` over Vapor Queues (building block; not wired by default).
- **LiqPay/** — the LiqPay adapters of the `PaymentGateway` port; see **Billing and LiqPay**.
- **Standard/** — small Foundation extensions shared by the adapters.

> `VaporQueueIntegrationEventChannel` and the **outbox relay** (`OutboxRelayJob` / `app.startOutboxRelay()`) ship as building blocks and are **not** wired into `CompositionRoot`/`configure` by default — add them when a module needs them. (The outbox *recording* side, `context.outbox`, is always wired; only the relay is opt-in, paired with the first use case that records integration events.)

### Persistence

Aggregate storage is **always a SQL database**, and that is a decision rather than a default: the two properties the architecture rests on both depend on it — one generic `Repository` over `DataSource` (because `SQLQueryEncoder`/`SQLRowDecoder` let a plain `Codable` struct *be* the row, so `DefaultUserRepository` needs no per-store code), and a read side free to drop to hand-written SQL. Nothing else sits behind the `DataSource` port.

Changing driver (SQLite ↔ Postgres) is **no code change at all** — `configureFluentStore` reads the environment; see **Environment Variables**. Everything above `Integration/` is identical either way, which is what makes the SQLite test suite a real check on the Postgres path.

The SQL database is reached through one dependency, `appDatabase`. That is also the **extension point**: a future snapshot or read-model store (streaming snapshots, a denormalized projection) registers as a *second dependency* beside it with its *own* types — never behind `DataSource`, never as an `AggregateRoot` source. Adding one means a property on `Application.Dependencies`, a `configure<Name>Store(_:)` that builds it, and the factories that need it resolving it. **`Lib/` needs no changes at all** — that is the point of the layering. More in [DEVELOPER_NOTES.md](DEVELOPER_NOTES.md#persistence-sqlite-postgres-and-the-seam).

## Testing

Tests use Swift Testing framework (`@Suite`, `@Test`, `#expect`). Test doubles in `Tests/ShowMenuBackendTests/Support/` are named `Spy*`/`Stub*`/`Recording*` so they never read as production types:

- `SpyDataSource<Model>` — replaces a real data source for unit tests, tracks `insertedModels`
- `SpyVersionedDataSource<Model: VersionedModel>` — like the above but implements optimistic-concurrency check-and-set in-body, for versioning tests
- `StubUnitOfWork` / `StubUnitOfWorkContext` — provides stub transaction, collector, and outbox channel; `StubUnitOfWork` commits/rolls back recorded outbox rows to `committedOutbox` with the work closure's success/failure
- `RecordingOutboxStore` — in-memory `OutboxStore` for relay/recording tests (`appended` capture, `failAppend` fault injection); `BufferingOutboxStore` models buffer-then-commit/rollback for atomicity tests
- `StubIdempotencyStore` — scriptable `IdempotencyStore` for reserve/complete tests
- `StubInboxStore` — scriptable `InboxStore` for consumer de-duplication tests
- `StubSQLDatabase` / `StubSQLRow` — a fake SQL database (conforming to both `SQLDatabase` and Fluent's `Database`) that captures the emitted SQL and returns canned rows, so the Fluent adapter's queries, CAS statements and row decoding are asserted **without a running Postgres**
- `SpyDomainEventDispatcher` / `SpyIntegrationEventDispatcher` / `SpyIntegrationEventChannel` — capture dispatched domain / integration events / published events for assertions
- `CapturingLogHandler` — captures log messages
- `StubPrincipal` — minimal `Principal` for authorization tests; set on a UseCase via `RequestContext.$principal.withValue(_:) { … }`

Tests that need the *real* transactional behaviour use a real in-memory SQLite database via the `withSQLiteDatabase` fixture rather than a double — `FluentSQLiteIntegrationTests` covers migrations, real transactions, real primary-key violations, `RETURNING`-based check-and-set, the plain-SQL page read and the `RequestContext`-across-the-transaction guard, and every `swift test` runs it. `FluentPostgresIntegrationTests` covers only what SQLite cannot answer — that Postgres accepts the emitted SQL, a native `text[]` column, and a genuinely concurrent CAS race — and is **skipped unless `POSTGRES_TEST_URL` is set**, so `swift test` still needs zero infrastructure.

Test pattern: `makeSUT()` creates the system under test with test doubles, allowing pure unit tests without any external service.

## Adding a New Module

1. Create `Modules/YourModule/` mirroring the IAM module structure (Domain → Application → Infrastructure → Presentation)
2. Declare the module's properties on the `Application.Dependencies` protocol in `Vapor+Dependencies.swift`, then implement them in a `Modules/YourModule/CompositionRoot+YourModule.swift` extension on `CompositionRoot` (mapper, data source factory, repository factory, use case factory, query/command handlers). Never put a module's resolutions in `Vapor+Dependencies.swift` — see `docs/conventions/CompositionRoot.md`
3. Add `Infrastructure/DataSource/Fluent<Entity>DataSource.swift` and `Infrastructure/Migration/Create<Entities>.swift` (a column per model coding key, in `snake_case`, plus indexes for whatever the module's queries filter on), and register the migration in `App/Fluent+Vapor.swift` with `to: .app`. For a read the DSL cannot express, add a narrow port in `Application/DataSource/` and a `Fluent<Entity>QueryDataSource` beside the CRUD one
4. Expose its operations contract-first: add them to `show-menu-contracts`, bump the tag in `Package.swift`, then add the `ContractAPI` witness — never register routes by hand (`docs/conventions/WireContract.md`)
