# Fluent

**The** persistence adapter: [Fluent](https://docs.vapor.codes/fluent/overview/)
over SQL, implementing every persistence port `Lib/` declares. Aggregate storage in
this app is always a SQL database — see *Why SQL only* below.

`configureFluentStore(app)` (called from `configure(_:)`) picks the driver from the
environment: **Postgres** when `DATABASE_URL` or `DATABASE_HOST` is set, an
**in-memory SQLite** database otherwise, so `swift run Run` and `swift test` need
nothing installed. Both go through everything in this folder; the app logs which one
it booted with. See *Running on Postgres* in `README.md`.

## The pieces

| File | Role |
| --- | --- |
| `FluentTransaction` | The transport-erased handle threaded through `UnitOfWorkContext.transaction`. `.transaction(…)` is the connection Fluent opened for a command; `.direct(…)` is for queries and the relay. Also vends the `SQLDatabase` beneath. |
| `FluentDataSource` (+`Query`, +`Concurrency`) | The `DataSource` / `QueryableDataSource` binding: CRUD, filter/order/limit pushed down into SQL, and check-and-set. |
| `FluentUnitOfWork` | The `UnitOfWork`: `database.transaction { … }` → work → commit → post-commit event dispatch. Also re-binds `RequestContext` across the transaction boundary — see *Design notes*. |
| `FluentOutboxStore` + `OutboxMessageRecord` | Transactional-outbox binding. `append` runs on the transaction's connection; the relay side runs direct. |
| `FluentIdempotencyStore` + `IdempotencyKeyRecord` | De-duplication record, written in the command's own transaction; the primary key *is* the in-flight guard. |
| `FluentInboxStore` + `InboxMessageRecord` | Consumer-side processed-event marker, written in the command's own transaction; same primary-key guard. |
| `FluentCoding` | The one row-coding configuration (snake_case columns, explicit `NULL`s) every binding shares. |
| `FluentStoreError` / `FluentQueryError` | Store-level failures, and queries the adapter refuses to fake. |
| `Migration/` | The adapter's own tables (`outbox`, `idempotency_keys`, `inbox`). Module tables live with their module, in `Modules/<Module>/Infrastructure/Migration/`. |

## Two bindings, on purpose

Fluent's ORM and its SQL layer are both used here, and which one appears where is a
deliberate consequence of the port being bound:

**Module data sources bind at the SQL layer** (`SQLKit`, reached via
`db as? any SQLDatabase`). `DataSource<Model>` is generic over an *opaque* `Codable`
store model — `UserModel` — while a `FluentKit.Model` is a bespoke
class per table with its columns spelled out as property wrappers. An ORM binding
would therefore need a second, hand-written record class plus a mapper for **every**
aggregate, and still could not build a `SET` clause generically (the API that
collects a model's pending column values is not public). `SQLQueryEncoder` /
`SQLRowDecoder` encode any `Encodable` straight into columns, so the store model
*is* the row and a module's data source stays four lines:

```swift
struct FluentUserDataSource: FluentDataSource, UserDataSource {
    typealias Model = UserModel
    let transaction: FluentTransaction
    let table = "users"
    let logger: Logger
    func documentId(for model: UserModel) -> String { model.id }
}
```

**The adapter's own tables use the ORM** (`OutboxMessageRecord`,
`IdempotencyKeyRecord`, `InboxMessageRecord`). Their schemas are fixed and known here, so there is no
genericity to fight and the typed query builder reads better than hand-written SQL:

```swift
try await OutboxMessageRecord.query(on: database)
    .filter(\.$status == OutboxMessage.Status.pending.rawValue)
    .filter(\.$availableAt <= now)
    .sort(\.$createdAt, .ascending)
    .sort(\.$sequence, .ascending)
    .limit(limit)
    .all()
```

Fluent owns everything around both: the connection pool, `db.transaction { … }`, and
migrations.

## Design notes

- **Check-and-set is one statement.** `UPDATE … SET …, version = $next WHERE id = $id
  AND version = $expected RETURNING id`. There is no read-then-write window to race,
  and `RETURNING` is what makes a conflict *detectable*: Fluent's
  `QueryBuilder.update()` returns `Void`, so a CAS that matched zero rows would be
  indistinguishable from success — a silently lost update. A zero-row result then
  costs one follow-up read, purely to name the actual token in the error.
  `Version.none` binds to `version IS NULL`, so rows predating versioning adopt it on
  their first write with no data migration. (`RETURNING` needs SQLite ≥ 3.35; the
  SQLite suite is the assertion that the toolchain's libsqlite has it.)
- **Concurrency conflicts are `ConcurrencyError`, never a store error** — the edge
  maps them to `409`/`412` identically for any store.
- **The outbox really enlists.** `append` runs on the transaction's connection, so the
  row commits atomically with the state change. On Postgres it is also genuinely
  durable: an unpublished message survives a crash, which is the point of the pattern.
  On the in-memory SQLite driver the *atomicity* holds and the durability does not —
  one warning at boot covers that.
- **Idempotency's guard is the primary key.** Two concurrent first-time requests with
  the same key cannot both `INSERT`; the loser's constraint violation aborts its
  whole transaction, and its retry observes the committed record and replays. The
  read-before-write ordering the port mandates is trivially satisfiable on SQL, but it
  is kept anyway — the contract exists so the *strictest* store can bind it.
- **A query never silently degrades.** A dotted field path addresses something
  *inside* a value, which a column does not hold; it throws `FluentQueryError` rather
  than returning unfiltered rows.
- **`RequestContext` is re-bound across the transaction boundary.** FluentKit bridges
  its async `transaction` through `eventLoop.makeFutureWithTask`, whose `Task { }` is
  created *on the event loop* and therefore inherits no task-locals. `FluentUnitOfWork`
  snapshots `RequestContext` before opening the transaction and restores it inside.
  Without that, every command would run with no principal (PEPs fail closed) and no
  idempotency key or event id (de-duplication silently off) — a failure mode with no
  error attached, which is why `FluentSQLiteIntegrationTests` pins it.
- **One handle for both altitudes.** Data sources, the outbox store and the
  idempotency store are written once against `FluentTransaction` and work inside a
  command transaction and outside it.

## Reads: the DSL, and plain SQL

Two read paths, and choosing between them is a judgement made per query.

**`DataSourceQuery` (the DSL)** — equality/comparison/`in` filters, ordering and a
limit, pushed down into `WHERE` / `ORDER BY` / `LIMIT`. Use it for the simple reads.
It carries *only* what any binding can translate, which is deliberate: a filter must
never silently degrade into an unfiltered read. It is not a query language, though —
no `OFFSET`, no case-insensitive matching, no joins, no aggregates, and no way to
return a total alongside a page.

**Plain SQL** — for everything else. `transaction.sql` vends the `SQLDatabase`
beneath the Fluent handle, so a module declares a narrow read port in its Application
layer and binds it in its own `Infrastructure/` with a hand-written statement — for
example search, offset and a total in one round trip.

```swift
var statement: SQLQueryString = "SELECT *, COUNT(*) OVER () AS \(ident: "total_count") FROM \(ident: table)"
statement = "\(statement) WHERE LOWER(\(ident: "display_name")) LIKE \(bind: pattern) ESCAPE '\\'"
let rows = try await transaction.sql.raw(statement).all()
let users = try rows.map { try FluentCoding.decode(UserModel.self, from: $0, table: table) }
```

Rules for hand-written reads:

- **`\(bind:)` for values, `\(ident:)` for identifiers.** Never interpolate a caller's
  value with `\(unsafeRaw:)`.
- **Decode through `FluentCoding`.** The store model *is* the row, and unknown extra
  columns (like `total_count`) are ignored — so a read can decode into the model, into
  a purpose-built `Codable` projection, or straight into a DTO.
- **Writes never come here.** They stay on Repository → `DataSource`, which is where
  lifecycle events and the `Version` check-and-set live.

### Dialect policy: portable-first

Hand-written SQL stays in the **SQLite ∩ Postgres** subset by default, so the same
statement runs on both drivers and the SQLite suite (which every `swift test` runs) is
a real portability check. In practice: `LOWER(…) LIKE …` rather than Postgres's
`ILIKE`, and an explicit `ESCAPE '\'` — load-bearing, because SQLite has no default
escape character, so without it a user searching for `%` would match every row.

A query that genuinely needs a Postgres-only feature is allowed. Mark it clearly and
cover it in the `POSTGRES_TEST_URL`-gated suite, so the two dialects cannot drift
silently.

## Why SQL only

The template used to ship a second, document-shaped adapter behind the same ports. It
was removed, because both invariants this architecture rests on depend on relational
storage:

1. **One generic repository.** `SQLQueryEncoder` / `SQLRowDecoder` let a plain
   `Codable` struct *be* the row, so `DefaultUserRepository` needs no per-store code.
2. **A read side free to drop to SQL.** The escape hatch above only exists because
   there is a query language underneath.

The adapter is reached through the `appDatabase` dependency. A future snapshot or
read-model store registers as its own dependency beside it — with its own types, never
behind `DataSource` and never as an `AggregateRoot` source.

## Adding a module

1. Give the store model `snake_case`-able coding keys (avoid acronym runs: `photoUrl`,
   not `photoURL` — see `FluentCoding.columnName(for:)`).
2. Add `Modules/<Module>/Infrastructure/DataSource/Fluent<Entity>DataSource.swift`
   (the four lines above).
3. Add `Modules/<Module>/Infrastructure/Migration/Create<Entities>.swift`, with a
   column per coding key plus indexes for whatever the module's queries filter on.
4. Register the migration in `registerMigrations` (`App/Fluent+Vapor.swift`) — with
   `to: .app`, the app store's own `DatabaseID` — and add the module's data-source
   factory in `Modules/<Module>/CompositionRoot+<Module>.swift`.
5. For a read the DSL cannot express, add a narrow port in the module's
   `Application/DataSource/` and a `Fluent<Entity>QueryDataSource` beside the CRUD
   one.

## Testing

Three layers, and only the last needs anything installed:

1. **Unit tests** run against a stub `SQLDatabase` that captures the emitted SQL, so
   query translation, CAS statements and row decoding are asserted without a server.
2. **`FluentSQLiteIntegrationTests`** runs the adapter against a real, in-memory
   SQLite database (`withSQLiteDatabase`): migrations, real transactions, real
   primary-key violations, real `RETURNING`-based check-and-set. The behavioural
   guarantees live here, and every `swift test` runs them.
3. **`FluentPostgresIntegrationTests`** covers only what SQLite cannot answer — that
   Postgres accepts the emitted SQL, a native `text[]` column, and a genuinely
   concurrent CAS race (SQLite serializes writers). **Skipped unless
   `POSTGRES_TEST_URL` is set:**

   ```bash
   docker compose --profile postgres up -d db
   POSTGRES_TEST_URL=postgres://vapor:vapor@localhost:5432/vapor swift test
   ```
