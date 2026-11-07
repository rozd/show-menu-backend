# Developer Notes

Technical reference for developers working on this codebase. For setup and deployment, see [README.md](README.md).

## Request Flow

```
Generated route (registerHandlers) → ContractAPI witness → Controller → CommandHandler/QueryHandler → UseCase → Repository → DataSource → Firestore
```

**Reads (Queries)** skip UnitOfWork — no transaction needed:

```
Controller → QueryHandler → DataSource → Firestore
```

**Writes (Commands)** go through UnitOfWork — domain events are collected during execution and dispatched after commit:

```
Controller → CommandHandler → UnitOfWork.execute { UseCase → Repository }
```

The CommandHandler wraps the UseCase in `unitOfWork.execute { ctx in ... }`. The `ctx` (`UnitOfWorkContext`) carries the active `FirestoreTransaction` (`context.transaction`) and a `DomainEventCollector`. After the closure completes and the transaction commits, collected events are dispatched to registered `DomainEventHandler`s.

## Dependency Injection

Shared infrastructure (transport, GCP config/auth, Firestore, the DDD dispatchers and `unitOfWork`) is wired in `App/Vapor+Dependencies.swift` via `CompositionRoot`; each module's factories live in a `Modules/<Module>/CompositionRoot+<Module>.swift` extension on `CompositionRoot`. Access from anywhere via `app.deps`.

### Resolver

The `Resolver` caches instances by keypath — each dependency is computed once and reused. It supports overrides for testing via `Partial<Dependencies>`.

### Factory closures

Repositories and UseCases are created **per-request** via factory closures:

| Type alias | Signature | Purpose |
|---|---|---|
| `RepositoryFactory<R>` | `@Sendable (UnitOfWorkContext) -> R` | Creates a repository bound to a transaction |
| `UseCaseFactory<U>` | `@Sendable (UnitOfWorkContext) -> U` | Creates a use case bound to a transaction |
| `DataSourceFactory<M>` | `@Sendable (String, any Sendable) -> any QueryableDataSource<M>` | Creates a data source for a collection prefix + transaction |

These factories receive a `UnitOfWorkContext` so that each operation shares the same `FirestoreTransaction` (`context.transaction`) and event collector.

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
| `toEntity(model:)` | Firestore model | Domain entity | Repository (fetch) |
| `toModel(entity:)` | Domain entity | Firestore model | Repository (insert) |
| `toDTO(entity:)` | Domain entity | API response DTO | UseCase (return value) |
| `toDTO(model:)` | Firestore model | API response DTO | QueryHandler (read path) |

The read path uses `toDTO(model:)` directly, bypassing entity creation for efficiency.

### DataSource vs Repository

- **DataSource** (`QueryableDataSource<Model>`) — raw CRUD (insert, update, delete, fetch) over Firestore models. Used directly by QueryHandlers for reads.
- **Repository** (`Repository<Entity, Model, DTO>`) — domain-level abstraction. Holds a `context: any UnitOfWorkContext`; resolves its DataSource via `dataSourceFactory("", context.transaction)` and reaches the event collector via `context.collector`. Works with entities, records domain events, delegates persistence to a DataSource. Exposes `insert`, `update`, and `delete`; conforming types implement `doInsert`, `doUpdate`, `doDelete`. Used by UseCases for writes.

### QueryableDataSource

Adds filtered/ordered query support via:

- `DataSourceQuery` — wraps filters + ordering + pagination
- `DataSourceFilter` — field-level predicates (`.equalTo`, `.greaterThan`, etc.)
- `DataSourceOrder` — field + direction sorting

## GCP Environment Detection

`Vapor+GCP.swift` auto-detects the runtime environment from environment variables:

| Environment | Detection | Auth Provider |
|---|---|---|
| **Emulator** | Both `FIRESTORE_EMULATOR_HOST` and `FIREBASE_AUTH_EMULATOR_HOST` set | `EmulatorAuthProvider` (no-op) |
| **Cloud Run** | `K_SERVICE` set | `GoogleAuthProvider(.applicationDefault)` (ADC → metadata server) |
| **Standalone** | otherwise; key path from `GOOGLE_APPLICATION_CREDENTIALS` (deprecated fallback: `GCP_SERVICE_ACCOUNT_JSON_PATH`) | `GoogleAuthProvider(.serviceAccountKey(_:))` (explicit key, not ADC) |

Detection runs in that order. Standalone with neither path variable set is a startup error, and the deprecated variable logs a warning. The provider is built once at startup in `GoogleCloudPlatform.fromEnvironment(environment:logger:)`, so bad credentials fail the boot.

Each `GCPAuthProvider` implements `func getAccessToken() async throws -> String?` to produce a bearer token for GCP REST/gRPC calls.

## Integration Layer

### Firestore (`Integration/Firestore/`)

- `FirestoreTransaction` (`Firestore+TransactionExtension`) — a transport-erased, `Sendable` wrapper over `Transaction<Transport>`. Created for a real transaction inside `Firestore.runInTransaction { … }`, or `.direct(firestore:)` for non-transactional reads. DataSources operate on this type, not on `Firestore` directly.
- `FirestoreTransactionUnitOfWork` — the production `UnitOfWork`. Runs the work closure inside `firestore.runInTransaction`, exposes the live `FirestoreTransaction` via `context.transaction`, and dispatches collected domain events after commit.
- `FirestoreDataSource<Model>` — generic CRUD data source over a `FirestoreTransaction`. Handles document serialization and collection paths.
- `FirestorePolymorphicDataSource` — single-collection store keyed by `PolymorphicDataKey<T>`, for heterogeneous values (building block; not wired by default).
- `FirestoreDataSource+Query` — translates `DataSourceQuery` into Firestore structured queries.
- `FirestoreError` — maps gRPC status codes to domain-friendly errors (not found, already exists, permission denied).

### Cloud Run (`Integration/CloudRun/`)

- `GCPAuthProvider` — protocol returning an OAuth2 bearer token. Impls: `GoogleAuthProvider` — backed by Google's `swift-google-auth` (`GoogleAuth` product); `.applicationDefault` (ADC → metadata server on Cloud Run) or `.serviceAccountKey(Data)`; scopes `cloud-platform` + `identitytoolkit`; the library caches the token and refreshes it proactively — and `EmulatorAuthProvider` (returns `"owner"`).
- `GoogleCloudPlatformLogHandler` — emits structured JSON log entries for Cloud Logging (severity, trace correlation, source location).
- `GoogleCloudPlatformTraceMiddleware` — propagates the `X-Cloud-Trace-Context` header into `RequestContext` so logs correlate to traces. Both are installed in `entrypoint.swift` when `K_SERVICE` is set.

### Firebase (`Integration/Firebase/`)

- `FirebaseCustomTokenMinter` — protocol `createCustomToken(uid:) -> String`. Per-environment impls: `ServiceAccountCustomTokenMinter` (RS256 via swift-crypto), `CloudRunCustomTokenMinter` (IAM `signBlob`), `EmulatorCustomTokenMinter` (unsigned `alg: none`). Building block; not wired by default.

### Cloud Tasks (`Integration/CloudTasks/`)

- `CloudTasksClient` — protocol for enqueuing HTTP tasks; `GCPCloudTasksClient` (REST) + `InMemoryCloudTasksClient` (test double). Building block; not wired by default.

### Pub/Sub (`Integration/PubSub/`)

- `PubSubClient` — publish / ensure-topic / ensure-subscription protocol; `GCPPubSubClient` (REST) + `InMemoryPubSubClient` (test double).
- `PubSubIntegrationEventChannel` — an `IntegrationEventChannel` that serializes integration events to Pub/Sub messages.
- `PubSubPushController` — decodes Pub/Sub **push** deliveries (no route: it is not in the OpenAPI contract, so it is not exposed until an operation is added there), decode the envelope, and dispatch the integration event (always return 200 to prevent retries). Building block; not wired by default.

### Eventarc (`Integration/Eventarc/`)

- `CloudEventsParser` — parses CloudEvents headers (`ce-type`, `ce-source`, `ce-subject`, etc.) from incoming webhooks.
- `EventarcController` (`Modules/IAM/Presentation/Controller/`) — serves `POST /api/v1/events/eventarc` (operation `handleEventarcEvent`), turning CloudEvents into integration events. Authentication: `EventarcAuthenticator`, applied by `ContractAccessMiddleware`.
- Supports Firebase Auth triggers (user created/deleted) out of the box.

### Integration Events

Cross-context events (between modules or from external sources):

- `IntegrationEvent` — protocol with `kind` (string discriminator), `id`, `metadata`
- `IntegrationEventHandler` — `func handle(_ event:) async throws` (throwing, unlike DomainEventHandler)
- `IntegrationEventChannel` — publishes events (`InMemoryIntegrationEventChannel`, `VaporQueueIntegrationEventChannel`, or `PubSubIntegrationEventChannel`)
- `IntegrationEventRegistry` — registers event types for deserialization by `kind`
- `IntegrationEventDispatcher` — routes deserialized events to their handlers

Two registration points are needed:
1. **Registry** — `registry.register(MyEvent.self)` — enables deserialization
2. **Dispatcher** — `dispatcher.register(handler)` — enables routing

## Adding a New Module

1. **Create the module directory** under `Sources/{APP_NAME}/Modules/YourModule/`

2. **Domain layer** — Entity (AggregateRoot), Event (DomainEvent + EventKind enum), Error, Repository protocol

3. **Infrastructure layer** — Firestore Model (Codable), FirestoreDataSource, FirestoreRepository

4. **Application layer** — DTO, Mapper, DataSource protocol, Command + Handler, Query + Handler, UseCase

5. **Presentation layer** — Controller (generated `Operations.X.Input/Output`), `ContractAPI+{Module}.swift` witness, wire mapper. Define the operations in `show-menu-contracts` first; see `docs/conventions/WireContract.md`

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

8. **Expose the operations** — contract first: add them to `show-menu-contracts/Sources/ShowMenuContracts/openapi.yaml`, release a tag, bump it in `Package.swift`, then add `Presentation/ContractAPI+{Module}.swift` forwarding to the controller and an entry per operation in `ContractAccessMiddleware.table`. No routes are registered by hand (`docs/conventions/WireContract.md`).

## Testing

### Framework

Tests use the **Swift Testing** framework (`@Suite`, `@Test`, `#expect`, `#require`) with `@testable import`.

### Test Doubles

Located in `Tests/{APP_NAME}Tests/Support/`:

| Double | Replaces | Key feature |
|---|---|---|
| `InMemoryDataSource<Model>` | `FirestoreDataSource` | Tracks `insertedModels`, `deletedIds`; supports `seed(models:)` |
| `StubUnitOfWork` | `FirestoreTransactionUnitOfWork` | Provides `StubUnitOfWorkContext` with in-memory collector |
| `StubUnitOfWorkContext` | `FirestoreTransactionUnitOfWorkContext` | Exposes `collector` for event assertions |
| `SpyDomainEventDispatcher` | `DomainEventDispatcher` | Captures dispatched events in `dispatchedEvents` |
| `CapturingLogHandler` | `LogHandler` | Records log messages for assertion |

### Test Pattern

Every UseCase test follows the `makeSUT()` pattern:

```swift
@Suite("FeatureUseCaseTests")
struct FeatureUseCaseTests {
    private func makeSUT() -> (
        ds: InMemoryDataSource<FeatureModel>,
        collector: InMemoryDomainEventCollector,
        context: StubUnitOfWorkContext
    ) {
        let ds = InMemoryDataSource<FeatureModel>(id: { $0.id })
        let collector = InMemoryDomainEventCollector()
        let context = StubUnitOfWorkContext(transaction: "stub", collector: collector)
        return (ds, collector, context)
    }

    private func makeRepoFactory(
        ds: InMemoryDataSource<FeatureModel>
    ) -> RepositoryFactory<any FeatureRepository> {
        { ctx in
            FirestoreFeatureRepository(
                mapper: FeatureMapper(),
                dataSourceFactory: { _, _ in ds },
                context: ctx
            )
        }
    }

    @Test("creates feature with valid input")
    func happyPath() async throws {
        let (ds, collector, context) = makeSUT()
        let sut = CreateFeatureUseCase(
            context: context,
            repositoryFactory: makeRepoFactory(ds: ds),
            mapper: FeatureMapper(),
            logger: Logger(label: "test")
        )

        let result = try await sut.execute(params: .init(category: "ai", name: ["en": "Test"], description: nil))

        #expect(result.name == ["en": "Test"])
        let inserted = await ds.insertedModels
        #expect(inserted.count == 1)
    }
}
```

**Key points:**
- `InMemoryDataSource` replaces Firestore — no network, no emulator needed
- `StubUnitOfWorkContext` provides the collector to capture domain events
- Assertions check both the return value (DTO) and side effects (inserted models, dispatched events)
- Seed data with `await ds.seed(models: [...])` for update/delete tests

## Cloud Build Pipeline

The `cloudbuild.yaml` runs four steps:

### Step 1: Cache Pull
```yaml
docker pull ${_REGION}-docker.pkg.dev/$PROJECT_ID/${_REPOSITORY_NAME}/${_SERVICE_NAME}:latest || exit 0
```
Pulls the previous `:latest` image to reuse Docker layers. `|| exit 0` ensures the build continues even on the first run when no image exists.

### Step 2: Docker Build
```yaml
DOCKER_BUILDKIT=1 docker build \
  -t ...:$SHORT_SHA \
  -t ...:latest \
  --cache-from ...:latest .
```
Builds with BuildKit. Tags with `$SHORT_SHA` (immutable, traceable) and `latest` (for caching next build). `--cache-from` reuses layers from the pulled image.

### Step 3: Push
Pushes the `$SHORT_SHA`-tagged image to Artifact Registry.

### Step 4: Deploy
```yaml
gcloud run deploy ${_SERVICE_NAME} \
  --image=...:$SHORT_SHA \
  --region=${_REGION} \
  --memory=512Mi \
  --platform=managed \
  --allow-unauthenticated \
  --min-instances=0 \
  --max-instances=5
```

### Substitution Variables

| Variable | Source | Description |
|---|---|---|
| `_REGION` | User-provided (trigger config) | GCP region |
| `_REPOSITORY_NAME` | User-provided (trigger config) | Artifact Registry repo name |
| `_SERVICE_NAME` | User-provided (trigger config) | Cloud Run service name |
| `$PROJECT_ID` | Cloud Build built-in | GCP project ID |
| `$SHORT_SHA` | Cloud Build built-in | Short commit hash |

### Timing

- First build: ~15 minutes (no cache, full Swift compilation)
- Cached builds: ~3-5 minutes (only changed layers rebuild)
- Timeout: 1800 seconds (30 minutes)

## Production Considerations

- **Scaling** — Adjust `--min-instances` and `--max-instances` in `cloudbuild.yaml`. Set `--min-instances=1` to eliminate cold starts (costs more).
- **Memory** — Default 512 MiB. Increase if you see OOM errors.
- **Authentication** — Template uses `--allow-unauthenticated`. Remove this and add [IAP](https://cloud.google.com/iap) or API keys for protected endpoints.
- **Custom domain** — Map via `gcloud run domain-mappings create`.
- **Secrets** — Use [Secret Manager](https://cloud.google.com/secret-manager) instead of environment variables for sensitive values.
- **Concurrency** — Swift 6.2 strict concurrency is enforced. All types are `Sendable`. Entity classes use `@unchecked Sendable`.
