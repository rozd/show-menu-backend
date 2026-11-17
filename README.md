# Show Menu Backend

Swift/Vapor backend for Show Menu (code name): QR menus for customers, an admin dashboard for restaurant owners, and LiqPay subscription payments. Built with **Domain-Driven Design (DDD)** and **CQRS** over a SQL database. PostgreSQL is the system of record and **Passage** handles authentication (it replaces Firebase Auth). Persistence is one adapter — Fluent — with two drivers behind it: **Postgres** when `DATABASE_URL` is set, and an in-memory **SQLite** fallback when nothing is configured, so the whole architecture (transactions, optimistic concurrency, a transactional outbox, idempotent commands, authorization) runs and is testable with **zero external services**. Nothing above the `DataSource` seam changes between them.

The HTTP API is generated from the OpenAPI contract in the private `show-menu-contracts` package (0.6.0); no routes are hand-written (see `docs/conventions/WireContract.md`). Passage mounts `/auth/*` and `/me` itself — the one library-owned exception.

This code is a restart from `vapor-standalone-template`; the previous implementation is at tag `v0.2.0` (`firestore-final`). See [docs/migration/restart-from-standalone-template.md](docs/migration/restart-from-standalone-template.md) for what was ported, dropped and still to be redesigned.

## Prerequisites

- **Swift 6.3+**
- **Docker** (optional — for containerized builds, and for a local Postgres)
- **Postgres** (optional — only when you move off the default SQLite driver)

That's the whole list. The default path needs no database and no cloud account.

## Quick Start

```bash
make build   # swift build
make run     # swift run Run serve
make test    # swift test
make db-up   # optional: a local Postgres
```

No environment variables, no configuration files, no services to start first.

## ⚠️ The default database is in-memory SQLite

With no connection details configured, the app runs on an in-memory SQLite database. Be clear-eyed about what that means:

- **All data is lost when the process exits.** There is no file, no snapshot, no WAL.
- **It does not work across instances.** Two replicas are two disjoint datasets; horizontal scaling silently corrupts your view of the world.
- It exists so the app boots, and is testable without infrastructure.

**Point it at Postgres before deploying anything you care about** (production requires `DATABASE_URL`) — see below. The app logs (and warns about) which database it booted with, so an operator can't mistake a demo for a deployment.

## Running on Postgres

Set the connection details; that is the whole switch — no code change, because both drivers are the same adapter:

```bash
make db-up                                       # or bring your own Postgres
export DATABASE_URL=postgres://vapor:vapor@localhost:5432/vapor
swift run Run                                    # migrations run automatically
```

On boot the app registers the database, applies any pending migrations, and logs `Store: postgres (Fluent)`. Without `DATABASE_URL` it warns instead, naming the in-memory SQLite database.

What changes: nothing at all in your code. The same commands, queries, use cases, outbox and idempotency layers run against the same tables and the same check-and-set on the `version` column — Postgres just makes them durable, concurrent and multi-instance. See [`Integration/Fluent/README.md`](Sources/ShowMenuBackend/Integration/Fluent/README.md) for how the adapter binds each port, the DSL-vs-plain-SQL split on the read side, and the portable-first dialect policy that keeps one statement running on both drivers.

## Authentication

**Passage** is wired as the authentication framework; it mounts `/auth/*` and `/me` itself. Authorization is handled by the IAM module (`Ability`/`Voter` checks in use cases).

### Example Flows

**Register a new account:**
```bash
curl -X POST http://localhost:8080/auth/register \
  -H "Content-Type: application/json" \
  -d '{
    "username": "alice",
    "password": "secret",
    "confirmPassword": "secret"
  }'
```

**Login to get a bearer token:**
```bash
curl -X POST http://localhost:8080/auth/login \
  -H "Content-Type: application/json" \
  -d '{
    "username": "alice",
    "password": "secret"
  }'
# Response: { "accessToken": "...", "user": { "id": "..." } }
```

**Use the token to call a protected endpoint:**
```bash
curl -X GET http://localhost:8080/me \
  -H "Authorization: Bearer <accessToken>"
```

The authenticated user is resolved through IAM (`RequestContext.principal`), so role changes take effect on the next request.

### Configuration

| Variable | Description |
|---|---|
| `APP_ORIGIN` | Public origin for Passage links (default: `http://localhost:<port>`) |
| `JWKS` | Inline JWKS JSON with the token-signing key |
| `JWKS_FILE_PATH` | Path to a JWKS file; used when `JWKS` is unset |

If neither `JWKS` nor `JWKS_FILE_PATH` is set, an **ephemeral dev key** is generated at boot — all access tokens become invalid on restart (fine for local development, wrong for anything else).

### Removing Authentication

Delete `configurePassage` call + bearer authenticator middleware + `Integration/Passage/` + `Modules/IAM/IAM+Passage.swift`, and add an alternative principal middleware before authorization checks run. See [AGENTS.md](AGENTS.md) for details.

## Environment Variables

Nothing is required. Everything below is optional:

| Variable | Required | Description |
|---|---|---|
| `PORT` | No | Server port (default: `8080`) |
| `LOG_LEVEL` | No | Log level passed to Vapor's logging bootstrap (`trace`…`critical`) |
| `DATABASE_URL` | No | Postgres connection URL for the Fluent adapter (wired in code — see **Running on Postgres** above) |
| `DATABASE_HOST` / `_PORT` / `_USERNAME` / `_PASSWORD` / `_NAME` | No | Connection details, used when `DATABASE_URL` is not set |
| `DATABASE_AUTO_MIGRATE` | No | `true` (default) applies pending migrations at boot; set `false` to run `swift run Run migrate` yourself |
| `APP_ORIGIN` | No | Public origin for Passage auth links (default: `http://localhost:<port>`) |
| `JWKS` | No | Inline JWKS JSON with the token-signing key; if unset, an ephemeral dev key is generated |
| `JWKS_FILE_PATH` | No | Path to a JWKS file; used when `JWKS` is unset |
| `CORS_ALLOWED_ORIGINS` | No | Comma-separated origins; unset installs no CORS middleware |
| `LIQPAY_PUBLIC_KEY` / `LIQPAY_PRIVATE_KEY` | No | Both set → the live LiqPay gateway. Otherwise `.development`/`.testing` use the fake gateway and any other environment an unconfigured one that refuses every call |

## Architecture

```
Sources/ShowMenuBackend/
├── entrypoint.swift          # Application entry point (trace middleware, lifecycle)
├── configure.swift           # App configuration, integration-event registration
├── routes.swift              # Route registration (HTTP routes come from the OpenAPI contract)
├── App/                      # Application wiring (DI / CompositionRoot, outbox relay opt-in)
├── Lib/                      # Generic DDD + CQRS + cross-cutting infrastructure (store-agnostic)
├── Integration/              # Adapters: Fluent SQL store, Passage, LiqPay, Vapor glue (access/error middleware, ETag, idempotency header, outbox job)
└── Modules/                  # Business modules
    ├── IAM/                  # Users (shared with Passage) + authorization pattern
    ├── Billing/              # PaymentGateway port (not exposed over HTTP yet)
    └── Shared/               # Money, LocalizedString
```

Each module in `Modules/` follows the DDD layering: **Domain** (Entity, Event, Error, Repository protocol, Specification) → **Application** (Command/Query, UseCase, DTO, Mapper, Authorization) → **Infrastructure** (store `Codable` Model, DataSource, Repository impl) → **Presentation** (controllers and contract witnesses, added with the contract).

For detailed architecture documentation — request flow, dependency injection, key patterns, swapping the persistence layer, and how to add modules — see [DEVELOPER_NOTES.md](DEVELOPER_NOTES.md).

## Testing

```bash
# Run all tests
swift test

# Run a single test suite
swift test --filter UserOnboardUseCaseTests

# Run a single test by name
swift test --filter "onboard"
```

Tests use the Swift Testing framework. Unit tests run against test doubles; the tests that need the real adapter run against an in-memory SQLite database. Either way: no services, no network. Only the Postgres-specific suite needs a server, and it is skipped unless `POSTGRES_TEST_URL` is set. See [DEVELOPER_NOTES.md](DEVELOPER_NOTES.md#testing) for test patterns and available doubles.

## Deployment

The app is a single statically-linked binary in a container. It listens on `PORT` (default 8080) and needs no configuration — beyond `DATABASE_URL`, if you want it to keep your data.

```bash
docker build --secret id=github_token,env=GITHUB_CONTRACTS_TOKEN -t show-menu-backend .
docker run -p 8080:8080 show-menu-backend
```

Or with Compose:

```bash
docker compose up app
```

The Compose `app` service runs `serve --env development`, so it boots with no configuration (in-memory SQLite, ephemeral signing key). The image's own default, `serve --env production`, refuses to start without `DATABASE_URL` and `JWKS`/`JWKS_FILE_PATH` — so the plain `docker run` above needs them too.

That image runs anywhere that takes a container — a VM, Kubernetes, a managed container service, a Raspberry Pi.

> **Before you deploy anything real:** set `DATABASE_URL` (and the Passage signing keys, `JWKS`; the Cloud Build wiring for both is still a TODO in `cloudbuild.yaml`). On the default in-memory SQLite database every restart wipes the data and every additional replica sees a different dataset, so a rolling deploy or an autoscaler is enough to lose writes. See **Running on Postgres**.

One other thing worth doing before production:

- **The outbox relay** — integration events are recorded transactionally but only published once a relay drains them. It is opt-in: call `try app.startOutboxRelay()` in `configure(_:)` (see `App/Outbox+Vapor.swift`).

## API Endpoints

The HTTP API is defined by the OpenAPI contract in `show-menu-contracts` and served by generated routes under `/api`. Implemented today:

| Endpoint | Operation | Access |
|---|---|---|
| `GET /api/v1/health` | `getHealth` | public |
| `GET /api/v1/version` | `getVersion` | public |

Every other contract operation answers `501 not_implemented` until it is implemented (the backlog is in the migration doc). Passage mounts its own `/auth/*` and `/me` routes outside `/api`.

Creating and deleting a user account emits `UserCreatedIntegrationEvent` / `UserDeletedIntegrationEvent`, which run follow-on work as a trusted `SystemPrincipal`.
