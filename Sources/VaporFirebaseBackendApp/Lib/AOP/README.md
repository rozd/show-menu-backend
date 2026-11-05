# AOP

Cross-cutting concerns — primitives that apply *across* bounded contexts rather than belonging to any single domain. Grouped under the `AOP` acronym for symmetry with the other `Lib` areas (`DDD`, `CQRS`, `FSM`).

> **Not an AOP framework.** There are no aspects, pointcuts, or weaving here — only plain Swift primitives whose *concern* is cross-cutting (authorization, idempotency, resilience) rather than tactical DDD/CQRS.

## Cross Cutting

### Authorization

Principal-aware authorization primitives — the `*Ability` / `*Voter` convention. Concrete abilities and voters live in each module's `Application/Authorization/`.

- `Ability` — named entry point for one authorization decision; `VotingAbility` aggregates voters.
- `Voter` — reusable `allow` / `deny` / `abstain` unit; `AnyVoter` type-eraser.
- `Decision` — `allowed` / `denied(reason:)` (never a bare `Bool`).
- `Vote` — `allow` / `deny(reason:)` / `abstain`.
- `VoteAggregation` — `VoteAggregationStrategy` + `DenyOverridesStrategy` (deny-overrides, default deny).
- `Principal` — minimal security identity (`id`, `roles: Set<Role>`) + `Role`.
- `AuthorizationError` — `denied(reason:)` / `missingPrincipal`.

### Idempotency

Inbound command de-duplication keyed on the client's `Idempotency-Key` header — a retry replays the first response instead of re-running the work. Implemented as a `CommandHandler`-refining protocol (conform to opt in) whose reserve/replay/store run **inside the command's own transaction**, so the de-duplication record and the command's writes commit atomically. The concrete store binding lives in `Integration/Firestore/`; the edge extraction in `Integration/Vapor/`.

- `IdempotencyKey` — validated header value type (request metadata, not a DTO field).
- `RequestFingerprint` — SHA-256 of the canonical payload; detects same-key-different-body misuse. Scope defaults to `command.payload`; a handler overrides `IdempotentCommandHandler.fingerprint(for:)` to fold in identity carried outside the payload (e.g. a route parameter like `itemId`).
- `IdempotencyRecord` / `StoredResponse` / `IdempotencyStatus` — the persisted record + captured response; `IdempotencyReservation` / `IdempotencyTicket` are the read-phase outcome and the proceed-token threaded to the write phase.
- `IdempotencyStore` — read-phase `reserve` + write-phase `complete` (the split honours Firestore's no-read-after-write rule).
- `IdempotencyConfiguration` — `IdempotencyScope` (default `actorAndCommandType`), TTL, `InFlightStrategy` (default `rejectConflict`).
- `IdempotentCommandHandler` — a protocol refining `CommandHandler` that supplies an idempotent `handle` default (a handler opts in by conforming); `IdempotencyComponents` bundles its store factory + configuration; `IdempotencyError` — `malformedKey` / `requestInProgress` / `fingerprintMismatch`.

### Resilience

Fault handling around outbound calls — retries for transient failures, a circuit breaker for degraded dependencies, a rate limiter for quota-bound ones.

- `RetryPolicy` — bounded in-process retries: `maxAttempts` + `Backoff` + `shouldRetry` predicate; `execute` rethrows the last error and never retries `CancellationError`.
- `RetryPolicy.Backoff` — the pure schedule (`initial`, `multiplier`, `cap`; `delay(forAttempt:)`), reused by the `Lib/DDD/Outbox` relay for cross-drain-pass backoff.
- `CircuitBreaker` — `actor`; closed→open→half-open fast-fail protection (trip after N consecutive failures, cooldown, single half-open probe); `CircuitBreakerOpenError` carries failure count / last error / `retryAfter`; injectable `now` clock.
- `RateLimiter` — `actor`; paces outbound calls to a dependency's published quota. `RateLimit` states that quota (`.perSecond(10)` / `.perMinute(600)` / `.every(_:)`) and derives `spacing = period / count`; `acquire()` *reserves* its slot before suspending (never "time since the last call" — that races under actor reentrancy).

All three share the `execute { … }` shape and nest, limiter innermost: `policy.execute { breaker.execute { limiter.execute { … } } }`.

The Firestore-aware preset (`RetryPolicy.firestore`, retrying only `FirestoreError.isRetryable`) lives in `Integration/Firestore/`.
