# Repository Guidelines

Guidance for Claude Code / Codex / Gemini when working with code in this repository.

## Project Overview

Swift/Vapor backend template deployed on Google Cloud Run with Firebase/Firestore. Uses **Domain-Driven Design (DDD)** with **CQRS** (Command Query Responsibility Segregation). Swift 6.2, strict concurrency (`Sendable` throughout).

## Build & Run Commands

```bash
# Build
swift build

# Run locally (requires env vars — see below)
swift run Run

# Run all tests
swift test

# Run a single test suite
swift test --filter FeatureUseCaseTests

# Run a single test by name
swift test --filter "create happy path"

# Docker build
docker build -t show-menu-backend .
docker compose up app
```

### Required Environment Variables

For emulator development:
```bash
export GCP_PROJECT_ID=demo-project
export FIRESTORE_EMULATOR_HOST=localhost:9002
export FIREBASE_AUTH_EMULATOR_HOST=localhost:9099
firebase emulators:start  # in a separate terminal
```

For real GCP project:
```bash
export GCP_PROJECT_ID=show-menu-dev
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
```

## Architecture

### Request Flow

```
Route → Controller → CommandHandler/QueryHandler → UseCase → Repository → DataSource → Firestore
```

**Reads (Queries)** skip UnitOfWork: `Controller → QueryHandler → DataSource → Firestore`
**Writes (Commands)** go through UnitOfWork: `Controller → CommandHandler → UnitOfWork.execute { UseCase → Repository }` — domain events are collected during execution and dispatched after commit.

### Dependency Injection

Dependencies are declared on the `Application.Dependencies` protocol in `App/Vapor+Dependencies.swift` and wired via `CompositionRoot`. Shared infrastructure (transport, GCP config/auth, Firestore, the DDD dispatchers, `outbox`/`outboxRelay` and `unitOfWork`, and the idempotency and inbox store factories/configs) lives in `Vapor+Dependencies.swift`; each module's factories live in a `Modules/<Module>/CompositionRoot+<Module>.swift` extension on `CompositionRoot`. Access from anywhere via `app.deps`. The `Resolver` caches instances by keypath and supports overrides for testing via `Partial<Dependencies>`. The contract is central, the resolutions are federated — the rule, the core/module split table and the file shape are in `docs/conventions/CompositionRoot.md`.

**Factory pattern**: Repositories and UseCases are created per-request via factory closures (`RepositoryFactory`, `UseCaseFactory`) that receive a `UnitOfWorkContext` — this passes the transaction and domain event collector into each operation.

### Module Structure (DDD Layers)

Each business module in `Modules/` follows this layering:

- **Domain** — `Entity/` (AggregateRoot), `Event/`, `Error/`, `Repository/` protocol, `Operation/` (cross-aggregate logic, see below), `Specification/` (actor-free domain-state rules). Pure business logic, no infrastructure imports.
- **Application** — `Command/` + `Query/` (CQRS), `UseCase/`, `DTO/`, `Mapper/`, `DataSource/` protocol, `Authorization/` (principal-aware `*Ability` + `Voter/`). Orchestration layer.
- **Infrastructure** — `Model/` (Firestore Codable), `DataSource/` impl, `Repository/` impl. Firestore-specific.
- **Presentation** — `Controller/` (HTTP handlers), `Route/` (Vapor RouteCollection).

### Key Patterns

- **Domain events** ride the `DomainEventRecorder` → `DomainEventCollector` pipeline (collected during UnitOfWork execution, **dispatched after commit**). Two kinds with different owners — *lifecycle* (Repository) vs *semantic* (AggregateRoot); see **Domain Events: Lifecycle vs Semantic** below.
- **Mapper** protocol has three conversion directions: `toEntity(model:)`, `toModel(entity:)`, `toDTO(entity:)`.
- **DataSource** vs **Repository**: DataSource is a raw CRUD interface (insert, update, delete, fetch) over Firestore models, executed through a `FirestoreTransaction` (a transport-erased wrapper over an active transaction, or `.direct(firestore:)` for non-transactional reads). Repository is the domain-level abstraction that works with entities, holds a `context: any UnitOfWorkContext`, resolves its DataSource via `dataSourceFactory("", context.transaction)`, and records **lifecycle** events (`created`/`updated`/`deleted`) on each `insert`/`update`/`delete`. QueryHandlers pass `.direct(firestore:)`; writes run inside `FirestoreTransactionUnitOfWork`, which threads the live `FirestoreTransaction` through `context.transaction`.
- **QueryableDataSource** adds filtered/ordered query support with `DataSourceQuery`, `DataSourceFilter`, `DataSourceOrder`, and `offset` (Firestore bills skipped docs as reads). `countAll()` returns the **unfiltered** collection total as a separate, non-atomic read (the only public count in the pinned client). No endpoint pages through it yet (the Items demo that did was removed in S04); the first list endpoint, `GET /plans` (S05), will. Search is not supported on Firestore: there is no substring match, and a prefix range would force `orderBy(name)` and be case-sensitive.
- **Optimistic concurrency** rides an opaque `Version` token carried by every `AggregateRoot`; writes are check-and-set and conflicts surface as `ConcurrencyError`. See **Optimistic Concurrency (Versioning)** below.
- **Transactional Outbox** makes integration-event delivery reliable: a use case records the event into a durable outbox **inside the command's transaction** (`context.outbox.record(_:)`) instead of publishing post-commit; a relay drains the outbox and publishes through the existing `IntegrationEventChannel`. Closes the commit-then-publish dual-write gap. See **Transactional Outbox (Reliable Integration Events)** below.
- **Inbox** (idempotent consumer, `Lib/DDD/Inbox/`) is the consumer side of the outbox: an `InboxedCommandHandler` de-duplicates redelivered integration events per consumer, keyed on `IntegrationEvent.id`, with the marker committed in the command's own transaction. See **Inbox (idempotent consumer)** below.
- **RetryPolicy** (`Lib/AOP/Resilience/`) wraps a transient-failure-prone outbound async call in bounded retries with capped exponential backoff: `try await policy.execute { … }`. Its nested pure schedule, `RetryPolicy.Backoff`, is reused by the outbox relay for cross-pass backoff. `RetryPolicy.firestore` (`Integration/Firestore/`) retries only `FirestoreError.isRetryable` failures. `CircuitBreaker` (same folder) adds closed→open→half-open fast-fail protection for outbound dependencies, and `RateLimiter` (same folder) paces calls to a quota-bound one (`RateLimiter(.perMinute(600))`) — its slots are *reserved* before the actor suspends, because the "time since the last call" form races under actor reentrancy. See **Resilience (Retry / Circuit Breaker / Rate Limiter)** below.
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
- **Delivery is at-least-once.** A crash after publish but before `markPublished` republishes on the next drain; **consumers must dedup** (the consumer-side **Inbox**, below, does exactly that). Note: since `IntegrationEventChannel.publish` is fire-and-forget, end-to-end delivery is "durably recorded and handed to the channel at least once" — the channel owns its own transport durability.
- **Placement.** Primitives in `Lib/DDD/Outbox/` (`Outbox` facade, `OutboxStore`, `OutboxMessage`, `OutboxIntegrationEventChannel`, `OutboxRelay`); Firestore binding in `Integration/Firestore/FirestoreOutboxStore.swift` (write enlists in the tx via buffered `create`; relay side uses `.direct(firestore:)`; status + sequence + timestamps, payload base64); relay job in `Integration/Vapor/OutboxRelayJob.swift`; wiring in `App/Outbox+Vapor.swift`. A Firestore Cloud Function trigger on outbox-doc creation is a lower-latency alternative relay; the polling job is the portable default.

### Inbox (idempotent consumer)

The consumer-side half of the reliable-messaging story — `Lib/DDD/Inbox/`, symmetric with `Lib/DDD/Outbox/`. The outbox makes delivery **at-least-once**; the inbox makes *processing* effectively-once by de-duplicating redelivered integration events per consumer, keyed on the event id every `IntegrationEvent` already carries (`id: UUID`).

- **`RequestContext.integrationEventId`** (`@TaskLocal`) — bound by `InMemoryIntegrationEventDispatcher` around every handler invocation (the message-boundary analogue of the HTTP edge binding `idempotencyKey`), so event handlers need no propagation code.
- **`InboxedCommandHandler`** — a protocol mixin refining `CommandHandler where Result == Void`: inbox consumers are fire-and-forget effects, so there is no stored response to replay and a duplicate is skipped **silently** (success, not an error). Same shape as `IdempotentCommandHandler`: the default `handle` opens one `unitOfWork.execute` and composes reserve → the conforming type's `perform` → complete inside it; with no bound event id (e.g. direct invocation) it is a transparent pass-through. The `Void` constraint means no handler can conform to both mixins — `IdempotentCommandHandler` requires `Result: Codable`. A conforming handler adds one stored `inbox: InboxComponents` (the store factory). Retention policy is **not** per-handler: `InboxConfiguration` is applied once, where `CompositionRoot.inboxStoreFactory` builds the store, so there is a single source of truth for the TTL.
- **`InboxStore`** — the same read-phase (`reserve`) / write-phase (`complete`) split as `IdempotencyStore`, for the same reason: the marker must enlist in the command's own transaction, and the pinned `FirebaseAPI` client forbids reads after writes. Only two outcomes: `proceed(ticket)` / `alreadyProcessed`. The record id (`InboxRecordId.derive`) is SHA-256 over (consumer command type + event id), so two consumers of one event each process it exactly once. Binding: `FirestoreInboxStore` (`Integration/Firestore/`, collection `inbox_records`): `reserve` reads the doc first; `complete` is the last write — a transactional `create` for an empty slot (`exists == false` is the uniqueness guard) or a `set` over an expired one. An undecodable record throws `InboxError.corruptRecord`.
- **Atomicity / crash behaviour:** marker and work commit in the **same** transaction — a crash mid-processing rolls both back and the redelivery reprocesses cleanly. A *concurrent* duplicate races: both probe an empty slot and run the work, but the `create` precondition is enforced at commit, so the loser's commit fails; the `FirebaseAPI` transaction runner retries the whole closure on **any** error (up to 5 attempts, with backoff), and the retry's `reserve` sees the winner's marker and skips silently. Only a conflict that outlasts every attempt escapes the unit of work (as a mapped `FirestoreError`) and is logged and swallowed by the dispatcher.
- **Retention:** records carry `expiresAt` (TTL via `InboxConfiguration`, default 7 days — a marker only needs to outlive the redelivery window; matches the outbox retention), a real `Timestamp` so a Firestore **TTL policy** on the field can reclaim documents; an expired probe is treated as an empty slot and overwritten.
- **Stable event ids at the boundary (critical):** the inbox can only recognise a redelivery if the redelivered event carries the *same* `IntegrationEvent.id`. An event minted at an inbound edge must therefore derive its id from the transport's own delivery identity, never a fresh `UUID()` per request. `EventarcWebhookController` does this via `CloudEventsHeaders.integrationEventId` — a name-based UUID over the CloudEvent's `ce-source` + `ce-id` (unique per event per the CloudEvents spec, and preserved by Eventarc on retry).
- **Worked example:** the IAM user-lifecycle command handlers (`CreateUserAccountCommandHandler`, `DeleteUserAccountCommandHandler`), wired in `CompositionRoot+IAM.swift` with `InboxComponents(storeFactory: inboxStoreFactory)` and fed by the Eventarc webhook's stable ids — so a redelivered `user.created` after a deletion is skipped (within the TTL) instead of recreating the user.

### Optimistic Concurrency (Versioning)

Every write is an **optimistic check-and-set** keyed on an abstract per-aggregate concurrency token.

- **`Version`** (`Lib/DDD/Concurrency/Version.swift`) is an **opaque** token carried by every `AggregateRoot` (`var version: Version`). The domain never inspects or hand-increments it — it is loaded with the aggregate, carried back on write, and advanced by the persistence layer. `.none` means "not yet persisted"; two `.none` tokens compare equal.
- **`ConcurrencyError`** (`Lib/DDD/Error/ConcurrencyError.swift`) — `.versionConflict(entity:id:expected:actual:)`, raised when the stored token no longer matches the loaded token.
- **Store binding (Firestore today):** the token is bound to a monotonic integer `version` field on the document (the store-agnostic `VersionedModel { var version: Int? }` in `Lib/DDD/Concurrency/VersionedModel.swift`; the Firestore check-and-set binding in `Integration/Firestore/Firestore+Concurrency.swift`). Check-and-set is realized inside `runTransaction` as **read current doc → compare `version` to expected → write `version + 1` or throw `ConcurrencyError`** (read precedes write; the transaction is a serializable backstop at commit). *Why an explicit field and not Firestore `updateTime`:* the pinned FirebaseAPI client neither exposes `updateTime` on reads nor accepts it as a write precondition (only `exists`). The abstraction is designed so a SQL store can later bind a `version` column / `xmin` to the same `Version`.
- **Ownership / flow:** the concrete **Repository** owns the token lifecycle — `doInsert` establishes the initial token, `doUpdate`/`doDelete` call the DataSource's `update(model:ifMatching:)` / `delete(byId:ifMatching:)` and advance the in-process token. The `DataSource` protocol carries those CAS methods with **default no-op implementations**, so only versioned stores opt in.
- **Conflict propagation:** `FirestoreTransactionUnitOfWork` surfaces `ConcurrencyError` **unchanged** through the CommandHandler — never collapses it into a generic Firestore error. Map it at the edge to `409 Conflict` (internal stale write) or `412 Precondition Failed` (stale `If-Match`).
- **No data migration:** an absent `version` field decodes to `nil` (`.none`) and matches a `.none` expected token, so existing documents adopt versioning on their first write.

**ETag at the edge (optional, separable):** `Integration/Vapor/ETag+Vapor.swift` provides reusable glue — `Version.etag`, `Request.ifMatch`, `Response.setETag`. Responses advertise the current version as an `ETag`; mutating endpoints read `If-Match`, reject a stale edit early with `412` (a fast pre-check before the transaction), and thread the precondition into the command where the in-transaction CAS is authoritative. **Currently unwired**: the Items demo that used it was removed in S04, and no Catalog endpoint sends `ETag`/`If-Match`. S06 deliberately left it off `PUT /plans/:id` (see roadmap §7); wire it when a client needs it. Creates don't need `If-Match`.

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
- **`IdempotencyStore`** — split into a **read phase** (`reserve` → probe) and a **write phase** (`complete` → persist), because the pinned `FirebaseAPI` client forbids reads after writes in a transaction. `FirestoreIdempotencyStore` (`Integration/Firestore/`) binds it: `reserve` reads the record doc *before* the work writes; `complete` is the *last* write, a transactional `create` (the `exists == false` precondition is the in-flight unique guard) or an overwrite for an expired slot. Records carry a TTL `expiresAt` (Firestore TTL-policy friendly); an expired probe is treated as empty.

**Protocol (reserve → run → store / replay):** new key → run the handler's `perform`, then store the response; *completed* duplicate → **replay** the stored response, never re-execute; *in-progress* duplicate → reject (`requestInProgress` → 409); *fingerprint differs* → reject (`fingerprintMismatch` → 422). Edge status mapping is `IdempotencyError: AbortError` in the Vapor layer.

**Atomicity (critical):** the de-duplication record and the command's writes commit in the **same** `UnitOfWork` transaction — a crash can't leave "marked-but-not-done" or "done-but-not-marked". This is achieved by the `CommandHandler` `perform(_:in:)` / `handle` split (mirrors `Repository.doInsert`/`insert`): `IdempotentCommandHandler`'s default `handle` opens one `unitOfWork.execute` and composes reserve/work/store around the conforming type's `perform` inside it — never a wrapper that opens its own connection.

**Defaults (configurable via `IdempotencyConfiguration`):** key scope `actorAndCommandType` (principal id + command type + key, hashed to the doc id); in-flight strategy `rejectConflict` (409, client retries — in practice the transaction runner's retry usually upgrades a concurrent duplicate to a clean replay); TTL 24h. **Currently unwired** (the Items demo that used it was removed in S04); the first consumer is the purchase endpoint, `POST /accounts/:accountId/purchases` (S11). The IAM user-lifecycle handlers do **not** conform to it — they conform to `InboxedCommandHandler` instead (see **Inbox (idempotent consumer)**), de-duplicating by integration event id.

### Resilience (Retry / Circuit Breaker / Rate Limiter)

`Lib/AOP/Resilience/` — the third cross-cutting concern under `Lib/AOP/`: fault handling around outbound calls. `RetryPolicy.swift` has two composable pieces:

- **`RetryPolicy.Backoff`** — a *pure* backoff schedule: capped exponential growth (`initial`, `multiplier`, `cap`). `delay(forAttempt: n)` is the wait after the n-th failure (`initial × multiplier^(n−1)`, capped). Build with `.exponential(initial:multiplier:cap:)`; use `.immediate` (all zeros) in tests. Pure math — assert on `delay(forAttempt:)` directly, no sleeping.
- **`RetryPolicy`** — in-process bounded retries: `maxAttempts` (total attempts, ≥ 1; `1` means no retry), a `Backoff`, and a `shouldRetry: (any Error) -> Bool` predicate (default: retry everything). `execute` runs the operation, sleeps per the schedule between attempts, and rethrows the *last* error when attempts are exhausted or the predicate declines. **Cancellation is never retried** — a thrown `CancellationError` propagates immediately, and the inter-attempt sleep is cancellation-transparent (no `try?` swallowing).

```swift
let policy = RetryPolicy(
    maxAttempts: 3,
    backoff: .exponential(initial: 1, multiplier: 2, cap: 30),
    shouldRetry: { ($0 as? FirestoreError)?.isRetryable ?? false }
)
let doc = try await policy.execute { try await dataSource.fetch(byId: id) }
```

`RetryPolicy.firestore` (`Integration/Firestore/RetryPolicy+Firestore.swift`) is exactly that preset. Usage rules:

- **Where it belongs:** around *outbound* infrastructure calls (Firestore reads, Cloud Tasks / Pub Sub REST, metadata server) in the Integration layer — not in UseCases/domain logic, and not around a whole `UnitOfWork` (Firestore's transaction runner already retries contention; stacking another retry there multiplies work).
- **Retry only transient failures** — pass a `shouldRetry` matched to the transport (e.g. `FirestoreError.isRetryable`). Blind retries of non-idempotent writes on ambiguous failures can duplicate work; pair with the Idempotency/Outbox machinery where that matters.
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
- **Per-process and in-memory** — every Cloud Run instance gets its own limiter. Size the limit per instance (vendor quota ÷ max instances), or use a distributed limiter when a single global quota must hold.
- **Cancellation propagates** — a caller cancelled while waiting throws `CancellationError` and does not run its operation. Its reserved slot is abandoned rather than reclaimed, which can only make pacing more conservative.
- **No injectable clock**, unlike `CircuitBreaker` — that one only *reads* time, so a `now` closure fully determinizes it; a limiter must actually sleep. Its tests use small real durations and assert **lower bounds only** (`Task.sleep` never returns early, so lower bounds are stable under CI noise; an upper bound on a sleep would be flaky).

Unwired building block. Composing the trio: retry outermost, limiter **innermost** so every retried attempt is paced — `policy.execute { try await breaker.execute { try await limiter.execute { … } } }`.

### GCP Environment Detection

`Vapor+GCP.swift` auto-detects three environments from env vars, in order: **emulator** (both `FIRESTORE_EMULATOR_HOST` and `FIREBASE_AUTH_EMULATOR_HOST` set) → `EmulatorAuthProvider`; **Cloud Run** (`K_SERVICE` set) → `GoogleAuthProvider(.applicationDefault)` (ADC, i.e. the metadata server); **standalone** → `GoogleAuthProvider(.serviceAccountKey(_:))` with the key file at `GOOGLE_APPLICATION_CREDENTIALS`, falling back to the deprecated `GCP_SERVICE_ACCOUNT_JSON_PATH` (logs a deprecation warning); neither set is a startup error. Standalone uses the explicit key, not ADC, so a developer's `gcloud` login is never picked up silently. The provider is built **once at startup** in `GoogleCloudPlatform.fromEnvironment(environment:logger:)` (called from `configure.swift`), so bad credentials fail the boot rather than the first request; detection takes an injectable `environment: [String: String]` for tests. Where Firebase custom tokens are needed, a matching `FirebaseCustomTokenMinter` is selected (emulator unsigned / Cloud Run `signBlob` / service-account RSA signing).

### Integration Layer (`Integration/`)

- **Firestore/** — `FirestoreDataSource<Model>` (CRUD) and `FirestorePolymorphicDataSource`, both executed over a transport-erased `FirestoreTransaction`; `Firestore+TransactionExtension` (the `FirestoreTransaction` wrapper, `runInTransaction`, `.direct(firestore:)`); `Firestore+Concurrency` (the `updateTime`-free check-and-set write path over a `VersionedModel`, which lives in `Lib/DDD/Concurrency/` — see **Optimistic Concurrency** above); `FirestoreTransactionUnitOfWork` (the production `UnitOfWork` — runs work inside a Firestore transaction, threads a transaction-bound `FirestoreOutboxStore` into `context.outbox`, and dispatches collected domain events after commit; surfaces `ConcurrencyError` unchanged); `FirestoreInboxStore` (the inbox binding — `reserve` reads, `complete` creates/overwrites the processed-event marker in the active transaction); `FirestoreOutboxStore` (the transactional-outbox binding — `append` enlists in the active transaction, relay reads/marks/prune via `.direct(firestore:)`); query builder support and gRPC error mapping.
- **CloudRun/** — `GCPAuthProvider` (`getAccessToken() async throws -> String?`) with impls `GoogleAuthProvider` (backed by Google's `swift-google-auth`, product `GoogleAuth`; scopes `cloud-platform` + `identitytoolkit`; token read from `Credentials.headers()`, cached and proactively refreshed by the library; the other impl, `EmulatorAuthProvider`, lives in `Integration/Emulators/`); `GoogleCloudPlatformLogHandler` (structured JSON Cloud Logging) and `GoogleCloudPlatformTraceMiddleware` (trace-context propagation), wired in `entrypoint.swift` when running on Cloud Run.
- **Firebase/** — `FirebaseCustomTokenMinter` with per-environment impls (`ServiceAccountCustomTokenMinter`, `CloudRunCustomTokenMinter`, `EmulatorCustomTokenMinter`).
- **CloudTasks/** — `CloudTasksClient` (`GCPCloudTasksClient` REST + `InMemoryCloudTasksClient` test double).
- **PubSub/** — `PubSubClient` (`GCPPubSubClient` + `InMemoryPubSubClient`), `PubSubIntegrationEventChannel` (publishes integration events), and `PubSubPushController` + `PubSubPushRouteV1` (receive Pub/Sub push deliveries and dispatch them).
- **Eventarc/** — CloudEvents webhook parsing for Firebase Auth triggers and the Firestore `accounts/{id}` create trigger (`FirestoreEventData`; POST `/`, guarded by `EventarcAuthMiddleware` — Google OIDC via `GoogleOIDCTokenVerifier` in `GoogleCloud/`, sharing `Firebase/JWKSKeyCache`; bypassed only in emulator mode; env `EVENTARC_OIDC_AUDIENCE`, `EVENTARC_ALLOWED_SERVICE_ACCOUNTS`); `CloudEventsHeaders.integrationEventId` derives a redelivery-stable integration event id from `ce-source` + `ce-id`.
- **Vapor/** — `ETag+Vapor` (the optional ETag/If-Match edge layer: `Version.etag`, `Request.ifMatch`, `Response.setETag`); `OutboxRelayJob` (the `AsyncScheduledJob` that drains the transactional outbox; scheduled by `App/Outbox+Vapor.swift`).

> Only the **auth token source** comes from `google-cloud-swift`. Firestore stays on the FirebaseAPI gRPC client and Pub/Sub on the hand-written REST `GCPPubSubClient`: `google-cloud-swift` has no Firestore or Pub/Sub package as of 2026-11-05. Cloud Tasks stays on the hand-written `GCPCloudTasksClient` too, although a generated `swift-google-cloud-tasks-v2` (0.6.0) now exists — a candidate for a later migration.

> CloudTasks, PubSub, the custom-token minters, `FirestorePolymorphicDataSource`, and the **outbox relay** (`OutboxRelayJob` / `app.startOutboxRelay()`) ship as building blocks and are **not** wired into `CompositionRoot`/`configure` by default — add them when a module needs them. (The outbox *recording* side, `context.outbox`, is always wired; only the relay is opt-in, paired with the first use case that records integration events.)

## Testing

Tests use Swift Testing framework (`@Suite`, `@Test`, `#expect`). Test doubles in `Tests/Support/`:

- `InMemoryDataSource<Model>` — replaces Firestore for unit tests, tracks `insertedModels`
- `InMemoryVersionedDataSource<Model: VersionedModel>` — like the above but implements optimistic-concurrency check-and-set in-body, for versioning tests
- `StubInboxStore` — scriptable in-memory `InboxStore` (`seedProcessed`, `completedIds`) for consumer de-duplication tests
- `StubUnitOfWork` / `StubUnitOfWorkContext` — provides stub transaction, collector, and outbox channel; `StubUnitOfWork` commits/rolls back recorded outbox rows to `committedOutbox` with the work closure's success/failure
- `InMemoryOutboxStore` — in-memory `OutboxStore` for relay/recording tests (`appended` capture, `failAppend` fault injection); `BufferingOutboxStore` models Firestore's buffer-then-commit/rollback for atomicity tests
- `SpyDomainEventDispatcher` / `SpyIntegrationEventDispatcher` / `SpyIntegrationEventChannel` — capture dispatched domain / integration events / published events for assertions
- `CapturingLogHandler` — captures log messages
- `StubPrincipal` — minimal `Principal` for authorization tests; set on a UseCase via `RequestContext.$principal.withValue(_:) { … }`

Test pattern: `makeSUT()` creates the system under test with in-memory collaborators, allowing pure unit tests without Firestore.

## Adding a New Module

1. Create `Modules/YourModule/` mirroring the Catalog module structure (Domain → Application → Infrastructure → Presentation)
2. Declare the module's properties on the `Application.Dependencies` protocol in `Vapor+Dependencies.swift`, then implement them in a `Modules/YourModule/CompositionRoot+YourModule.swift` extension on `CompositionRoot` (mapper, data source factory, repository factory, use case factory, query/command handlers). Never put a module's resolutions in `Vapor+Dependencies.swift` — see `docs/conventions/CompositionRoot.md`
3. Register routes in `routes.swift`
