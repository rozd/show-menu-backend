# Developer Notes

Technical reference for developers working on this codebase. For setup and deployment, see [README.md](README.md).

## Request Flow

```
Route → Controller → CommandHandler/QueryHandler → UseCase → Repository → DataSource → Store
```

**Reads (Queries)** skip UnitOfWork — no transaction needed:

```
Controller → QueryHandler → DataSource → Store
```

**Writes (Commands)** go through UnitOfWork — domain events are collected during execution and dispatched after commit:

```
Controller → CommandHandler → UnitOfWork.execute { UseCase → Repository }
```

The CommandHandler wraps the UseCase in `unitOfWork.execute { ctx in ... }`. The `ctx` (`UnitOfWorkContext`) carries the active store transaction (`context.transaction` — a `FluentTransaction`), a `DomainEventCollector`, and the transaction-bound outbox channel. After the closure completes and the transaction commits, collected events are dispatched to registered `DomainEventHandler`s.

## Dependency Injection

Shared infrastructure (transport, the store `database`, the DDD dispatchers and `unitOfWork`) is wired in `App/Vapor+Dependencies.swift` via `CompositionRoot`; each module's factories live in a `Modules/<Module>/CompositionRoot+<Module>.swift` extension on `CompositionRoot`. Access from anywhere via `app.deps`.

### Resolver

The `Resolver` caches instances by keypath — each dependency is computed once and reused. It supports overrides for testing via `Partial<Dependencies>`.

### Factory closures

Repositories and UseCases are created **per-request** via factory closures:

| Type alias | Signature | Purpose |
|---|---|---|
| `RepositoryFactory<R>` | `@Sendable (UnitOfWorkContext) -> R` | Creates a repository bound to a transaction |
| `UseCaseFactory<U>` | `@Sendable (UnitOfWorkContext) -> U` | Creates a use case bound to a transaction |
| `DataSourceFactory<M>` | `@Sendable (String, any Sendable) -> any QueryableDataSource<M>` | Creates a data source for a collection prefix + transaction |

These factories receive a `UnitOfWorkContext` so that each operation shares the same store transaction (`context.transaction`) and event collector.

### Wiring a new dependency

Declare a property on the `Application.Dependencies` protocol (in `Vapor+Dependencies.swift`), then implement it in the module's `CompositionRoot+<Module>.swift` extension:

```swift
// Protocol
var myUseCaseFactory: UseCaseFactory<MyUseCase> { get }

// CompositionRoot
var myUseCaseFactory: UseCaseFactory<MyUseCase> {
    resolver.resolve(\.myUseCaseFactory) {
        { [logger = app.logger] ctx in
            MyUseCase(
                context: ctx,
                repositoryFactory: myEntityRepositoryFactory,
                mapper: myEntityMapper,
                logger: logger
            )
        }
    }
}
```

## Key Patterns

### AggregateRoot and Domain Events

Entities extending `AggregateRoot` record domain events via `DomainEventRecorder`. The flow:

1. Entity method calls `events.record(.created)` (or `.updated`, `.deleted`, custom kinds)
2. Repository's `doInsert`/`doUpdate`/`doDelete` flushes recorded events to the `DomainEventCollector` (accessed via `context.collector` from `UnitOfWorkContext`)
3. After `UnitOfWork.execute` commits, the dispatcher calls all registered `DomainEventHandler`s

Domain event handlers are **fire-and-forget** — `handle(event:)` is `async` (not `async throws`). Errors must be caught and logged inside the handler.

### Operation (cross-aggregate domain logic)

An **Operation** is stateless, pure domain logic that coordinates **2+ `AggregateRoot`s** (or expresses logic belonging to no single aggregate). It is a **convention** like `Policy` — **not** a protocol or base class, and nothing lives under `Lib/` for it.

- Lives in `Modules/<Module>/Domain/Operation/`, named for the activity with **no suffix** (`TransferFunds`, not `TransferFundsOperation`) — modeled as a caseless `enum` with a single static, pure entry point.
- **Pure**: no Repository, no `async`, no transaction awareness, no I/O, no injected dependencies. Throws domain errors only; composes `Policy` and `Specification`.
- The UseCase keeps pure orchestration: load aggregates via the Repository → call the Operation → persist. Cross-aggregate decisions move **out of the UseCase and into the Operation**.

See [`docs/conventions/Operation.md`](docs/conventions/Operation.md) for rules and a before/after example.

### Mapper

The `Mapper` protocol defines three conversion directions:

| Method | From | To | Used by |
|---|---|---|---|
| `toEntity(model:)` | Store model | Domain entity | Repository (fetch) |
| `toModel(entity:)` | Domain entity | Store model | Repository (insert) |
| `toDTO(entity:)` | Domain entity | API response DTO | UseCase (return value) |
| `toDTO(model:)` | Store model | API response DTO | QueryHandler (read path) |

The read path uses `toDTO(model:)` directly, bypassing entity creation for efficiency.

### DataSource vs Repository

- **DataSource** (`QueryableDataSource<Model>`) — raw CRUD (insert, update, delete, fetch) over store models. Used directly by QueryHandlers for reads.
- **Repository** (`Repository<Entity, Model, DTO>`) — domain-level abstraction. Holds a `context: any UnitOfWorkContext`; resolves its DataSource via `dataSourceFactory("", context.transaction)` and reaches the event collector via `context.collector`. Works with entities, records domain events, delegates persistence to a DataSource. Exposes `insert`, `update`, and `delete`; conforming types implement `doInsert`, `doUpdate`, `doDelete`. Used by UseCases for writes.

### QueryableDataSource

Adds filtered/ordered query support via:

- `DataSourceQuery` — wraps filters + ordering + pagination
- `DataSourceFilter` — field-level predicates (`.equalTo`, `.greaterThan`, etc.)
- `DataSourceOrder` — field + direction sorting

## Integration Layer

Everything store- or framework-specific lives under `Integration/`. `Lib/` never imports from it — that separation is what makes the store swappable.

### SQL store (`Integration/Fluent/`)

The persistence adapter: Fluent over SQL, wired by `configureFluentStore(app)` in `configure(_:)`. It picks its driver from the environment — Postgres when `DATABASE_URL` (or `DATABASE_HOST`/`_PORT`/`_USERNAME`/`_PASSWORD`/`_NAME`) is set, an **in-memory SQLite** database otherwise, so the template boots with nothing installed. Both are the same adapter; only the dialect differs. Its own [README](Sources/ShowMenuBackend/Integration/Fluent/README.md) has the full picture, including the read-side DSL-vs-plain-SQL split and the portable-first dialect policy. The essentials:

- `FluentTransaction` — the transport-erased handle. `.transaction(database:)` wraps the connection Fluent opened for a command (statements enlist automatically); `.direct(database:)` is for query handlers and the relay. It also vends the `SQLDatabase` beneath the Fluent handle. There is no write buffer — Postgres has a real transaction, so "enlisting" is just issuing statements on that connection.
- `FluentDataSource` (+`Query`, +`Concurrency`) — the `DataSource` binding. It works at the **SQL layer** rather than through Fluent's ORM, because `DataSource<Model>` is generic over an opaque `Codable` model while a `FluentKit.Model` is a bespoke class per table: `SQLQueryEncoder`/`SQLRowDecoder` let the store model *be* the row, so a module's data source is four lines and needs no record class or mapper. Filters, orders and limits are pushed down into SQL; a dotted field path throws rather than returning unfiltered rows.
- **Plain-SQL reads.** `DataSourceQuery` deliberately carries only what any binding can push down, so it has no `OFFSET`, no case-insensitive matching and no way to return a total with a page. Reads that need more get a narrow, module-owned port bound with hand-written SQL over `transaction.sql`.
- `FluentUnitOfWork` — `database.transaction { … }`, with domain events dispatched **after** commit and `ConcurrencyError` surfaced unchanged. It also **re-binds `RequestContext` inside the transaction**: FluentKit runs the closure in a `Task` started on the event loop, which inherits no task-locals, so without `RequestContext.snapshot`/`restore(_:)` every command would run with no principal and no idempotency key — silently.
- `FluentOutboxStore` / `FluentIdempotencyStore` / `FluentInboxStore` — these three *do* use Fluent's ORM (`OutboxMessageRecord`, `IdempotencyKeyRecord`, `InboxMessageRecord`): their schemas are fixed, so there is no genericity to fight and the typed query builder reads better. The idempotency and inbox tables' **primary key is the in-flight guard** — a duplicate `INSERT` violates it and aborts the transaction.
- `FluentCoding` — the one row-coding configuration: camelCase coding keys → `snake_case` columns, `nil` written as an explicit `NULL` (so an update clears a column instead of leaving a stale value), and the same transform applied to query field names so a filter on `createdAt` reaches `created_at`.
- `Migration/` — the adapter's own tables. A module's table lives with the module, in `Modules/<Module>/Infrastructure/Migration/`, and is registered in `App/Fluent+Vapor.swift`.

Optimistic concurrency is a single conditional statement — `UPDATE … SET …, version = $next WHERE id = $id AND version = $expected RETURNING id` — so there is no read-then-write window at all. `RETURNING` is load-bearing: Fluent's `QueryBuilder.update()` returns `Void`, and a CAS that matched zero rows would otherwise look like success.

### Vapor glue (`Integration/Vapor/`)

Framework integration, independent of the store:

- `TraceMiddleware` — reads `X-Request-ID` (falling back to `X-Correlation-ID`), or generates an id, and populates `RequestContext.traceId` so logs and downstream commands/events correlate to one request. Installed at the beginning of the middleware chain in `entrypoint.swift`.
- `ETag+Vapor` — `Version.etag`, `Request.ifMatch`, `Response.setETag`: the optional ETag/`If-Match` edge layer over optimistic concurrency.
- `IdempotencyKey+Request` — `IdempotencyKeyMiddleware`, lifting the `Idempotency-Key` header into `RequestContext`.
- `OutboxRelayJob` — the `AsyncScheduledJob` draining the outbox; scheduled by `App/Outbox+Vapor.swift` via `try app.startOutboxRelay()` (opt-in).
- `VaporQueueIntegrationEventChannel` — an `IntegrationEventChannel` over Vapor Queues. Building block; not wired by default.

### Standard (`Integration/Standard/`)

Small Foundation extensions shared by the adapters.

### Integration Events

Cross-context events (between modules or from external sources):

- `IntegrationEvent` — protocol with `kind` (string discriminator), `id`, `metadata`
- `IntegrationEventHandler` — `func handle(_ event:) async throws` (throwing, unlike DomainEventHandler)
- `IntegrationEventChannel` — publishes events (`InProcessIntegrationEventChannel` for in-process delivery, `VaporQueueIntegrationEventChannel` for queue-based transport)
- `IntegrationEventRegistry` — registers event types for deserialization by `kind`
- `IntegrationEventDispatcher` — routes deserialized events to their handlers

Two registration points are needed:
1. **Registry** — `registry.register(MyEvent.self)` — enables deserialization
2. **Dispatcher** — `dispatcher.register(handler)` — enables routing

For *reliable* cross-process delivery, don't publish after commit — record into the transactional outbox inside the command's transaction (`context.outbox.record(_:)`) and let the relay publish. See the Transactional Outbox section in [AGENTS.md](AGENTS.md).

## Persistence: SQLite, Postgres, and the seam

Aggregate storage is **always a SQL database**. That is a decision, not a default: the two properties the architecture rests on both depend on it — one generic `Repository` over `DataSource` (because `SQLQueryEncoder`/`SQLRowDecoder` let a plain `Codable` struct *be* the row), and a read side free to drop to hand-written SQL. A document or key-value store satisfies neither, so none sits behind `DataSource`.

### Changing driver

There is no code change. `configureFluentStore` reads the environment:

| | SQLite (default) | Postgres |
|---|---|---|
| Selected by | nothing configured | `DATABASE_URL`, or `DATABASE_HOST` + `DATABASE_USERNAME` |
| Durable / multi-instance | no / no | yes / yes |
| Concurrency | single writer | real concurrent writers |
| Announced at boot as | a warning | `Store: postgres (Fluent)` |

Everything above `Integration/` is identical either way, which is what makes the SQLite suite a genuine test of the Postgres path — see the *Dialect policy* in the adapter's README for the rule that keeps it so.

### The extension point

The SQL database is reached through one dependency, `appDatabase` on `Application.Dependencies`. A *future* store — a streaming-snapshot store, a denormalized read model — registers as its **own** dependency beside it, with its **own types**, never behind the `DataSource` port and never as an `AggregateRoot` source. Adding one means a property on the protocol, a `configure<Name>Store(_:)` that builds it, and the factories that need it resolving it; `Lib/`, Domain, Application and Presentation stay untouched.

### What must **not** change

**`Lib/` needs no changes** for any of this. If a persistence change tempts you to edit anything under `Lib/`, the abstraction has sprung a leak — fix the leak rather than the library. The same goes for the Domain, Application and Presentation layers of every module: only `Infrastructure/` is store-aware.

### Practical notes

- Keep the **read-before-write** ordering that `IdempotencyStore` and `InboxStore` assume. SQL does not need it; the port keeps it so the contract stays satisfiable on a stricter store, and it documents why the API is split at all.
- Keep `ConcurrencyError` distinct from generic store errors all the way to the edge — the ETag layer depends on telling `409` from `500`.
- The outbox's atomicity guarantee only holds if `append` really joins the command's transaction.
- **Make a failed check-and-set detectable.** An update API that cannot report how many rows it affected makes a CAS that matched nothing indistinguishable from success — a silently lost update. That is why the adapter uses `RETURNING`.

## Adding a New Module

1. **Create the module directory** under `Sources/{APP_NAME}/Modules/YourModule/`

2. **Domain layer** — Entity (AggregateRoot), Event (DomainEvent + EventKind enum), Error, Repository protocol

3. **Infrastructure layer** — store model (`Codable`, plus `VersionedModel` for check-and-set), concrete DataSource, concrete Repository

4. **Application layer** — DTO, Mapper, DataSource protocol, Command + Handler, Query + Handler, UseCase

5. **Presentation layer** — Controller, RouteCollection

6. **Vapor integration** — `{Module}+Vapor.swift` with `extension {Entity}DTO: Content {}`

7. **Wire dependencies** — declare the properties on the `Application.Dependencies` protocol in `Vapor+Dependencies.swift`, then implement them in a new `Modules/YourModule/CompositionRoot+YourModule.swift` extension on `CompositionRoot`:
   ```swift
   // Add to the Application.Dependencies protocol:
   var entityMapper: EntityMapper { get }
   var entityDataSourceFactory: DataSourceFactory<EntityModel> { get }
   var entityRepositoryFactory: RepositoryFactory<any EntityRepository> { get }
   var createEntityUseCaseFactory: UseCaseFactory<CreateEntityUseCase> { get }
   var getEntityQueryHandler: GetEntityQueryHandler { get }
   var listEntitiesQueryHandler: ListEntitiesQueryHandler { get }
   var createEntityCommandHandler: CreateEntityCommandHandler { get }
   ```

8. **Register routes** in `routes.swift`:
   ```swift
   let entityController = EntityController(
       getEntityQueryHandler: app.deps.getEntityQueryHandler,
       listEntitiesQueryHandler: app.deps.listEntitiesQueryHandler,
       createEntityCommandHandler: app.deps.createEntityCommandHandler
   )
   try app.register(collection: EntityRouteV1(controller: entityController))
   ```

## Testing

### Framework

Tests use the **Swift Testing** framework (`@Suite`, `@Test`, `#expect`, `#require`) with `@testable import`.

### Test Doubles

Located in `Tests/{APP_NAME}Tests/Support/`. They are named `Spy*` / `Stub*` / `Recording*` so they never read as production types:

| Double | Replaces | Key feature |
|---|---|---|
| `SpyDataSource<Model>` | a concrete DataSource | Tracks `insertedModels`, `deletedIds`; supports `seed(models:)` |
| `SpyVersionedDataSource<Model>` | a versioned DataSource | Implements check-and-set in-body, for optimistic-concurrency tests |
| `StubUnitOfWork` | `FluentUnitOfWork` | Provides `StubUnitOfWorkContext`; commits/rolls back recorded outbox rows to `committedOutbox` |
| `StubUnitOfWorkContext` | the real UnitOfWork context | Exposes `collector` (event assertions), stub transaction and outbox channel |
| `RecordingOutboxStore` | `FluentOutboxStore` | Captures `appended` rows; `failAppend` fault injection |
| `BufferingOutboxStore` | `FluentOutboxStore` | Models buffer-then-commit/rollback, for atomicity tests |
| `StubIdempotencyStore` | `FluentIdempotencyStore` | Scriptable reserve/complete outcomes |
| `StubInboxStore` | `FluentInboxStore` | Scriptable reserve/complete outcomes for consumer de-duplication |
| `StubSQLDatabase` / `StubSQLRow` | a live Postgres | Conforms to both `SQLDatabase` and Fluent's `Database`; captures emitted SQL and returns canned rows, so the Fluent adapter is testable with no server |
| `SpyDomainEventDispatcher` | `DomainEventDispatcher` | Captures dispatched events in `dispatchedEvents` |
| `SpyIntegrationEventDispatcher` / `SpyIntegrationEventChannel` | their real counterparts | Capture dispatched / published integration events |
| `CapturingLogHandler` | `LogHandler` | Records log messages for assertion |
| `StubPrincipal` | `Principal` | Minimal identity for authorization tests |

Tests that need genuine transactional behaviour (real transactions, real primary-key violations, `RETURNING`-based check-and-set) use a real in-memory SQLite database via the `withSQLiteDatabase` fixture instead of a double — the default driver needs no external service, so there is nothing to fake. Only `FluentPostgresIntegrationTests` needs a server, and it is skipped unless `POSTGRES_TEST_URL` is set.

The Fluent adapter's unit tests assert the **SQL it emits** against `StubSQLDatabase`. The properties only a live database can prove — migrations apply, a real CAS race, an outbox row vanishing with a rolled-back transaction, the idempotency primary-key violation — live in `Tests/{APP_NAME}Tests/Integration/` and are skipped unless `POSTGRES_TEST_URL` is set:

```bash
docker compose --profile postgres up -d db
POSTGRES_TEST_URL=postgres://vapor:vapor@localhost:5432/vapor swift test
```

### Test Pattern

Every UseCase test follows the `makeSUT()` pattern:

```swift
@Suite("UserOnboardUseCase")
struct UserOnboardUseCaseTests {
    private func makeSUT() -> (
        ds: SpyDataSource<UserModel>,
        collector: InProcessDomainEventCollector,
        context: StubUnitOfWorkContext
    ) {
        let ds = SpyDataSource<UserModel>(id: { $0.id })
        let collector = InProcessDomainEventCollector()
        let context = StubUnitOfWorkContext(transaction: "stub", collector: collector)
        return (ds, collector, context)
    }

    private func makeRepoFactory(
        ds: SpyDataSource<UserModel>
    ) -> RepositoryFactory<any UserRepository> {
        { ctx in
            DefaultUserRepository(
                mapper: UserMapper(),
                dataSourceFactory: { _, _ in ds },
                context: ctx
            )
        }
    }

    @Test("happy path inserts user and records created event")
    func onboard_happyPath() async throws {
        let (ds, collector, context) = makeSUT()
        let useCase = UserOnboardUseCase(
            context: context,
            repositoryFactory: makeRepoFactory(ds: ds),
            logger: Logger(label: "test")
        )

        try await useCase.execute(params: .init(
            userId: User.Id(rawValue: "u-1"),
            email: "alice@example.com",
            displayName: "Alice"
        ))

        #expect(await ds.insertedModels.count == 1)
        #expect(await collector.drain().count == 1)
    }
}
```

**Key points:**
- `SpyDataSource` stands in for the module's data source — no store, no transaction semantics, just recorded calls
- `StubUnitOfWorkContext` provides the collector to capture domain events
- Assertions check both the return value (DTO) and side effects (inserted models, dispatched events)
- Seed data with `await ds.seed(models: [...])` for update/delete tests

## Production Considerations

- **Persistence first.** The *default* driver is in-memory SQLite: non-durable and single-instance. Nothing else on this list matters until you set `DATABASE_URL` — see [Persistence: SQLite, Postgres, and the seam](#persistence-sqlite-postgres-and-the-seam).
- **Scaling.** On Postgres the app is stateless and scales horizontally; the only in-process state is the outbox relay's schedule (safe to run on several instances since delivery is at-least-once and consumers dedup) and the in-process integration-event channel (move to a real transport for multi-instance delivery).
- **Authentication.** Passage is wired and mounts `/auth/*` and `/me` itself; contract-served routes are guarded per operation (wired with the contract). `PassagePrincipalMiddleware` binds the authenticated user to `RequestContext.principal`, resolving roles through IAM's `User` query handler on every request. Authorization checks (`Ability`/`Voter`) are enforced by use cases; PEPs fail closed if the principal is unset. To remove Passage: delete `configurePassage` call, the middleware group, and `Integration/Passage/` + `Modules/IAM/IAM+Passage.swift`.
- **Secrets.** Read them from the environment at startup in `configure(_:)`; there is deliberately no secret store binding.
- **Logging.** `LOG_LEVEL` selects the level at bootstrap. `TraceMiddleware` populates `RequestContext.traceId` — include it in structured log metadata so a request can be reconstructed.
- **Concurrency.** Swift 6.3 toolchain; strict concurrency is enforced. All types are `Sendable`; entity classes use `@unchecked Sendable`.
