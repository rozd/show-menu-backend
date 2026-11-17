---
name: create-module
description: Scaffold a new DDD module with all layers (Domain, Application, Infrastructure, Presentation) and unit tests following the IAM module pattern.
argument-hint: "[ModuleName]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion
---

# Create a New DDD Module

You are scaffolding a new module for this Vapor DDD/CQRS backend. The module name is: **$ARGUMENTS**

## Pre-flight

1. Read `Package.swift` to find the library target name (the `APP_NAME`, e.g. `ShowMenuBackend`).
2. Derive the singular entity name from the module name (e.g. `Items` → `Item`, `Orders` → `Order`). If the module name is already singular, use it as-is.
3. Verify the module does not already exist by checking `Sources/{APP_NAME}/Modules/$ARGUMENTS/`.

## Step 1 — Ask Questions

Use `AskUserQuestion` to ask the following (you may combine into one call with up to 4 questions):

### Question 1: Entity Properties
Ask: "What properties should the {Entity} entity have?" with options:
- **Use defaults** — `name: String` and `description: String?` (same as the IAM module)
- **Specify properties** — The user will list them

If the user specifies properties, parse them as `propertyName: Type` pairs. Each property will flow through Entity → Model → DTO → Mapper → UseCase params → Command payload.

### Question 2: Domain Events
Ask: "Any domain events beyond standard create/update/delete?" with options:
- **Standard only** — Just created/updated/deleted lifecycle events
- **Add custom events** — The user will specify additional event kinds

### Question 3: Use Cases
Ask: "What use cases should this module support?" with options:
- **CRUD** — Create + Get + List (same as the IAM module)
- **Specify use cases** — The user will list them

### Fallback
If the user provides no entity or use case details, infer a single entity from the module name and create a `Create{Entity}UseCase` with `name: String` and `description: String?` properties (mirroring Items).

## Step 2 — Derive Names

From the module name and entity, derive all type names:

| Concept | Pattern | Example (Module=Orders, Entity=Order) |
|---|---|---|
| Module directory | `{Module}` | `Orders` |
| Entity class | `{Entity}` | `Order` |
| Entity ID | `{Entity}.Id` | `Order.Id` |
| Domain event | `{Entity}Event` | `OrderEvent` |
| Event kind enum | `{Entity}EventKind` | `OrderEventKind` |
| Not-found error | `{Entity}NotFoundError` | `OrderNotFoundError` |
| Repository protocol | `{Entity}Repository` | `OrderRepository` |
| Store model | `{Entity}Model` | `OrderModel` |
| DTO | `{Entity}DTO` | `OrderDTO` |
| Mapper | `{Entity}Mapper` | `OrderMapper` |
| DataSource protocol | `{Entity}DataSource` | `OrderDataSource` |
| Concrete DataSource | `Fluent{Entity}DataSource` | `FluentOrderDataSource` |
| Plain-SQL read port (optional) | `{Entity}QueryDataSource`, `Fluent{Entity}QueryDataSource` | `OrderQueryDataSource`, `FluentOrderQueryDataSource` |
| Concrete Repository | `Default{Entity}Repository` | `DefaultOrderRepository` |
| Migration (Fluent) | `Create{Entities}` | `CreateOrders` |
| Create command | `Create{Entity}Command` | `CreateOrderCommand` |
| Create command handler | `Create{Entity}CommandHandler` | `CreateOrderCommandHandler` |
| Create use case | `Create{Entity}UseCase` | `CreateOrderUseCase` |
| Get query | `Get{Entity}Query` | `GetOrderQuery` |
| Get query handler | `Get{Entity}QueryHandler` | `GetOrderQueryHandler` |
| List query | `List{Module}Query` | `ListOrdersQuery` |
| List query handler | `List{Module}QueryHandler` | `ListOrdersQueryHandler` |
| Controller | `{Entity}Controller` | `OrderController` |
| Route | `{Entity}RouteV1` | `OrderRouteV1` |
| Store collection | `{module}` (lowercased) | `orders` |
| Route path | `{module}` (lowercased) | `orders` |
| URL param | `{entity}Id` (camelCase) | `orderId` |

## Step 3 — Create Files

**All module source files** go under `Sources/{APP_NAME}/Modules/{Module}/`.
**All module test files** go under `Tests/{APP_NAME}Tests/Unit/Modules/{Module}/`.

Read the corresponding IAM module file as reference before writing each file. The IAM module files are at `Sources/{APP_NAME}/Modules/IAM/`. Follow the exact same patterns, protocols, and conventions.

### File Inventory

Create these files in order:

#### Domain Layer

1. **`Domain/Entity/{Entity}.swift`**
   - `final class {Entity}: AggregateRoot, @unchecked Sendable`
   - `typealias Event = {Entity}Event`
   - Properties: `id: {Entity}.Id`, `events: DomainEventRecorder<Event>`, `var version: Version = .none` (required by `AggregateRoot`; the domain never inspects or increments it), user-specified properties, `createdAt: Date?`, `updatedAt: Date?`
   - Nested `Id: EntityId` with `rawValue: String`
   - Nested `Error: ValidationError` with validation cases matching properties
   - Static `validate(...)` method that throws on invalid input
   - Reference: `Modules/IAM/Domain/Entity/User.swift`

2. **`Domain/Event/{Entity}Event.swift`**
   - `enum {Entity}EventKind: String, LifecycleEventKind` with `.{entity}Created`, `.{entity}Updated`, `.{entity}Deleted` plus any custom events
   - `struct {Entity}Event: DomainEvent` with `typealias AggregateId = {Entity}.Id`, `typealias Kind = {Entity}EventKind`
   - Reference: `Modules/IAM/Domain/Event/UserEvent.swift`

3. **`Domain/Error/{Entity}Error.swift`**
   - `struct {Entity}NotFoundError: Error` with `{entity}Id: {Entity}.Id`
   - Reference: `Modules/IAM/Domain/Error/UserError.swift`

4. **`Domain/Repository/{Entity}Repository.swift`**
   - `protocol {Entity}Repository: Repository where Entity == {Entity}, Model == {Entity}Model, DTO == {Entity}DTO {}`
   - Reference: `Modules/IAM/Domain/Repository/UserRepository.swift`

#### Infrastructure Layer

5. **`Infrastructure/Model/{Entity}Model.swift`**

   ```swift
   import Foundation

   struct {Entity}Model: Codable, Sendable, VersionedModel {
       var id: String
       let {prop1}: {Type1}
       let {prop2}: {Type2}?

       /// Optimistic-concurrency counter. Absent on documents written before
       /// versioning (decodes to `nil`), which the store treats as `Version.none`.
       var version: Int?

       let createdAt: Date?
       let updatedAt: Date?
   }
   ```

   - A plain `Codable` struct — no property wrappers, no store-specific value types. Dates are `Date?`.
   - Conform to `VersionedModel` (`var version: Int?`) so the repository's check-and-set path works.
   - Reference: `Modules/IAM/Infrastructure/Model/UserModel.swift`

6. **`Infrastructure/DataSource/Fluent{Entity}DataSource.swift`**

   ```swift
   import Logging

   struct Fluent{Entity}DataSource: FluentDataSource, {Entity}DataSource {
       typealias Model = {Entity}Model

       let transaction: FluentTransaction
       let table = "{module}"
       let logger: Logger

       func documentId(for model: {Entity}Model) -> String {
           model.id
       }
   }
   ```

   - `FluentDataSource` supplies every CRUD/query/check-and-set method as a default implementation; the concrete type only declares its transaction, table, logger and how to derive a row's primary key.
   - `table` is the lowercased, pluralized module name.
   - Reference: `Modules/IAM/Infrastructure/DataSource/FluentUserDataSource.swift`

6b. **`Infrastructure/Migration/Create{Entities}.swift`** — one column per model coding key in `snake_case`, plus indexes for whatever the module's queries filter on. Register it in `registerMigrations` (`App/Fluent+Vapor.swift`) with `to: .app` — the app store's own `DatabaseID`, deliberately not Fluent's default.
   - Reference: `Modules/IAM/Infrastructure/Migration/CreateUsers.swift`

6c. **Plain-SQL reads (only if the module needs them).** `DataSourceQuery` carries equality/comparison/`in` filters, ordering and a limit — nothing more, so a filter can never silently degrade into an unfiltered read. A read that needs search, `OFFSET`, a total alongside a page, a join or an aggregate gets its own narrow port in `Application/DataSource/{Entity}QueryDataSource.swift` and a hand-written binding in `Infrastructure/DataSource/Fluent{Entity}QueryDataSource.swift`, over `transaction.sql`. Use `\(bind:)` for values and `\(ident:)` for identifiers, decode through `FluentCoding`, and stay in the SQLite ∩ Postgres subset.
   - Reference: `Modules/IAM/Application/Query/Handler/FindUserQueryHandler.swift`

7. **`Infrastructure/Repository/Default{Entity}Repository.swift`**
   - `struct Default{Entity}Repository: {Entity}Repository` — store-agnostic (it talks to `DataSource`, not to a store)
   - Holds `mapper`, `dataSourceFactory: DataSourceFactory<{Entity}Model>`, and `context: any UnitOfWorkContext`; resolves its data source via `dataSourceFactory("", context.transaction)`
   - Implements `fetch(byId:)`, `doInsert(entities:)`, `doUpdate(entities:)`, `doDelete(entities:)`
   - Owns the `Version` token lifecycle: `doInsert` establishes the initial token, `doUpdate`/`doDelete` pass `ifMatching: entity.version` and advance the in-process token
   - Uses mapper for entity↔model conversion
   - Reference: `Modules/IAM/Infrastructure/Repository/DefaultUserRepository.swift`

#### Application Layer

8. **`Application/DTO/{Entity}DTO.swift`**
   - `struct {Entity}DTO: Sendable, Codable`
   - All properties as API-friendly types (Date → `String?` as ISO8601)
   - Reference: `Modules/IAM/Application/DTO/UserDTO.swift`

9. **`Application/Mapper/{Entity}Mapper.swift`**
   - `struct {Entity}Mapper: Mapper, Sendable`
   - Implements `toModel(entity:)`, `toEntity(model:)`, `toDTO(entity:)`, `toDTO(model:)`
   - Date handling: model `Date?` ↔ entity `Date?` ↔ DTO ISO8601 `String?`
   - Reference: `Modules/IAM/Application/Mapper/UserMapper.swift`

10. **`Application/DataSource/{Entity}DataSource.swift`**
    - `protocol {Entity}DataSource: QueryableDataSource<{Entity}Model> {}`
    - Reference: `Modules/IAM/Application/DataSource/UserDataSource.swift`

11. **`Application/Command/Create{Entity}Command.swift`**
    - `struct Create{Entity}Command: Command` with nested `Payload` containing the entity's required creation properties
    - Reference: `Modules/IAM/Application/Command/CreateUserAccountCommand.swift`

12. **`Application/Command/Handler/Create{Entity}CommandHandler.swift`**
    - `struct Create{Entity}CommandHandler: CommandHandler`
    - Wraps use case execution inside `unitOfWork.execute`
    - Reference: `Modules/IAM/Application/Command/Handler/CreateUserAccountCommandHandler.swift`

13. **`Application/UseCase/Create{Entity}UseCase.swift`**
    - `struct Create{Entity}UseCase: UseCase`
    - Nested `Params` struct with creation properties
    - Validates input, creates entity, records `.created` event, inserts via repository, returns DTO
    - Reference: `Modules/IAM/Application/UseCase/UserOnboardUseCase.swift`

14. **`Application/Query/Get{Entity}Query.swift`**
    - `struct Get{Entity}Query: Query` with `{entity}Id: String`
    - Reference: `Modules/IAM/Application/Query/GetUserQuery.swift`

15. **`Application/Query/Handler/Get{Entity}QueryHandler.swift`**
    - `struct Get{Entity}QueryHandler: QueryHandler`
    - Fetches from data source, maps model → DTO
    - Reference: `Modules/IAM/Application/Query/Handler/GetUserQueryHandler.swift`

16. **`Application/Query/List{Module}Query.swift`**
    - `struct List{Module}Query: Query {}` (empty, like ListItemsQuery)
    - Reference: `Modules/IAM/Application/Query/FindUserQuery.swift`

17. **`Application/Query/Handler/List{Module}QueryHandler.swift`**
    - `struct List{Module}QueryHandler: QueryHandler`
    - Queries all from data source, maps models → DTOs
    - Reference: `Modules/IAM/Application/Query/Handler/FindUserQueryHandler.swift`

#### Presentation Layer

18. **`Presentation/Controller/{Entity}Controller.swift`**
    - `struct {Entity}Controller: Sendable`
    - Handlers: `get{Entity}(req:)`, `list{Module}(req:)`, `create{Entity}(req:)`
    - All marked `@Sendable`
    - Error handling: validation errors (`{Entity}.Error`) → 400, missing route parameter → 400, not found (`ApplicationError.notFound`) → 404, `ConcurrencyError` → 412 when the request carried `If-Match`, else 409. Anything else falls through to 500 — add a store-specific `catch` arm only if the store has a distinguishable error worth translating. Mirror `ItemController` rather than inventing a mapping
    - Reference: `the contract witnesses (`docs/conventions/WireContract.md`)`

19. **`Presentation/Route/{Entity}RouteV1.swift`**
    - `struct {Entity}RouteV1: RouteCollection`
    - Routes under `"v1", "{module}"` (lowercased)
    - GET → list, GET `":{entity}Id"` → get, POST → create
    - Reference: `the contract witnesses (`docs/conventions/WireContract.md`)`

#### Integration

20. **`{Module}+Vapor.swift`**
    - `import Vapor` + `extension {Entity}DTO: Content {}`
    - Reference: `Modules/IAM/IAM+Vapor.swift`

### Additional Use Cases

For each additional use case beyond Create (e.g., Update, Delete):
- Create `{Action}{Entity}Command.swift` and `Handler/{Action}{Entity}CommandHandler.swift`
- Create `{Action}{Entity}UseCase.swift`
- Add the handler to the Controller and Route
- Create corresponding test file

## Step 4 — Create Tests

Create test files under `Tests/{APP_NAME}Tests/Unit/Modules/{Module}/`.

For each use case, create `{Action}{Entity}UseCaseTests.swift`:

- Use Swift Testing framework (`@Suite`, `@Test`, `#expect`, `#require`)
- Import the app module as `@testable import {APP_NAME}`
- Follow the `makeSUT()` pattern from `CreateItemUseCaseTests`:
  - Create `SpyDataSource<{Entity}Model>` with id extractor `{ $0.id }` (the test double in `Tests/{APP_NAME}Tests/Support/` — **not** the real `FluentDataSource` adapter)
  - Create `InProcessDomainEventCollector`
  - Create `StubUnitOfWorkContext`
- Create `makeRepoFactory(ds:)` helper
- Test cases:
  - **Happy path** — execute with valid params, assert DTO fields, assert `insertedModels`, assert domain events
  - **Validation error** — execute with invalid params (e.g., empty required field), assert throws `{Entity}.Error`
  - **Optional fields** — execute with nil optional fields, assert success
- Reference: `Tests/{APP_NAME}Tests/Unit/Modules/IAM/UserOnboardUseCaseTests.swift`

## Step 5 — Update Documentation

### README.md
- In the **API Endpoints** section, add a new subsection for the module's endpoints (similar to "Sample Items Module"):

```markdown
### {Module}

| Method | Path | Description |
|---|---|---|
| GET | `/v1/{module}` | List all {module} |
| GET | `/v1/{module}/:{entity}Id` | Get {entity} by ID |
| POST | `/v1/{module}` | Create a new {entity} |
```

### AGENTS.md
- No changes needed (the architecture docs are generic enough).

## Step 6 — Summary

After creating all files, output:

1. **Created files** — list all files created with their paths
2. **Wiring instructions** — tell the user exactly what to add to `Vapor+Dependencies.swift`, the new `CompositionRoot+{Module}.swift`, and `routes.swift`:

### Add to the `Application.Dependencies` protocol in `Vapor+Dependencies.swift`:
```swift
// MARK: {Module}
var {entity}Mapper: {Entity}Mapper { get }
var {entity}DataSourceFactory: DataSourceFactory<{Entity}Model> { get }
var {entity}RepositoryFactory: RepositoryFactory<any {Entity}Repository> { get }
var create{Entity}UseCaseFactory: UseCaseFactory<Create{Entity}UseCase> { get }
var get{Entity}QueryHandler: Get{Entity}QueryHandler { get }
var list{Module}QueryHandler: List{Module}QueryHandler { get }
var create{Entity}CommandHandler: Create{Entity}CommandHandler { get }
```

### Create `Modules/{Module}/CompositionRoot+{Module}.swift`:
An `extension Application.CompositionRoot { … }` holding the full implementation block, following `Modules/IAM/CompositionRoot+IAM.swift` (mapper, data source factory, repository factory, use case factory, query handlers, command handler). Repositories take `context: ctx` and resolve their data source via `dataSourceFactory("", context.transaction)` — no separate `transaction:` argument.

### Add to `routes.swift`:
```swift
// {Module}
let {entity}Controller = {Entity}Controller(
    get{Entity}QueryHandler: app.deps.get{Entity}QueryHandler,
    list{Module}QueryHandler: app.deps.list{Module}QueryHandler,
    create{Entity}CommandHandler: app.deps.create{Entity}CommandHandler
)
try app.register(collection: {Entity}RouteV1(controller: {entity}Controller))
```

## Important Rules

- **Swift 6.2 strict concurrency**: All types must be `Sendable`. Entities use `@unchecked Sendable`. Closures use `@Sendable`.
- **No file header comments**: Do not add `// Created by...` or `// Copyright...` header comments to generated files.
- **Trailing commas**: Use trailing commas in function calls and collections (Swift 6.2 style, matching the IAM module).
- **Imports**: Only import what's needed. Domain layer imports only `Foundation`. Infrastructure imports `Foundation` and `Logging`. Presentation imports `Vapor`.
- **Logging**: Use structured logging with metadata. Debug level for operations, trace for results, info for use case execution, error for failures.
- **Write constraints**: Only write files into `Sources/{APP_NAME}/Modules/{Module}/`, `Tests/{APP_NAME}Tests/Unit/Modules/{Module}/`, and documentation files (README.md).
