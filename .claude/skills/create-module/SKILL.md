---
name: create-module
description: Scaffold a new DDD module with all layers (Domain, Application, Infrastructure, Presentation) and unit tests following the Items module pattern.
argument-hint: "[ModuleName]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion
---

# Create a New DDD Module

You are scaffolding a new module for this Vapor/Firebase backend. The module name is: **$ARGUMENTS**

## Pre-flight

1. Read `Package.swift` to find the executable target name (the `APP_NAME`, e.g. `ShowMenuBackend`).
2. Derive the singular entity name from the module name (e.g. `Items` → `Item`, `Orders` → `Order`). If the module name is already singular, use it as-is.
3. Verify the module does not already exist by checking `Sources/{APP_NAME}/Modules/$ARGUMENTS/`.

## Step 1 — Ask Questions

Use `AskUserQuestion` to ask the following (you may combine into one call with up to 4 questions):

### Question 1: Entity Properties
Ask: "What properties should the {Entity} entity have?" with options:
- **Use defaults** — `name: String` and `description: String?` (same as Items module)
- **Specify properties** — The user will list them

If the user specifies properties, parse them as `propertyName: Type` pairs. Each property will flow through Entity → Model → DTO → Mapper → UseCase params → Command payload.

### Question 2: Domain Events
Ask: "Any domain events beyond standard create/update/delete?" with options:
- **Standard only** — Just created/updated/deleted lifecycle events
- **Add custom events** — The user will specify additional event kinds

### Question 3: Use Cases
Ask: "What use cases should this module support?" with options:
- **CRUD** — Create + Get + List (same as Items module)
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
| Firestore model | `{Entity}Model` | `OrderModel` |
| DTO | `{Entity}DTO` | `OrderDTO` |
| Mapper | `{Entity}Mapper` | `OrderMapper` |
| DataSource protocol | `{Entity}DataSource` | `OrderDataSource` |
| Firestore DataSource | `Firestore{Entity}DataSource` | `FirestoreOrderDataSource` |
| Firestore Repository | `Firestore{Entity}Repository` | `FirestoreOrderRepository` |
| Create command | `Create{Entity}Command` | `CreateOrderCommand` |
| Create command handler | `Create{Entity}CommandHandler` | `CreateOrderCommandHandler` |
| Create use case | `Create{Entity}UseCase` | `CreateOrderUseCase` |
| Get query | `Get{Entity}Query` | `GetOrderQuery` |
| Get query handler | `Get{Entity}QueryHandler` | `GetOrderQueryHandler` |
| List query | `List{Module}Query` | `ListOrdersQuery` |
| List query handler | `List{Module}QueryHandler` | `ListOrdersQueryHandler` |
| Controller | `{Entity}Controller` | `OrderController` |
| Route | `{Entity}RouteV1` | `OrderRouteV1` |
| Firestore collection | `{module}` (lowercased) | `orders` |
| Route path | `{module}` (lowercased) | `orders` |
| URL param | `{entity}Id` (camelCase) | `orderId` |

## Step 3 — Create Files

**All module source files** go under `Sources/{APP_NAME}/Modules/{Module}/`.
**All module test files** go under `Tests/{APP_NAME}Tests/Unit/Modules/{Module}/`.

Read the corresponding Items module file as reference before writing each file. The Items module files are at `Sources/{APP_NAME}/Modules/Items/`. Follow the exact same patterns, protocols, and conventions.

### File Inventory

Create these files in order:

#### Domain Layer

1. **`Domain/Entity/{Entity}.swift`**
   - `final class {Entity}: AggregateRoot, @unchecked Sendable`
   - `typealias Event = {Entity}Event`
   - Properties: `id: {Entity}.Id`, `events: DomainEventRecorder<Event>`, user-specified properties, `createdAt: Date?`, `updatedAt: Date?`
   - Nested `Id: EntityId` with `rawValue: String`
   - Nested `Error: ValidationError` with validation cases matching properties
   - Static `validate(...)` method that throws on invalid input
   - Reference: `Modules/Items/Domain/Entity/Item.swift`

2. **`Domain/Event/{Entity}Event.swift`**
   - `enum {Entity}EventKind: String, LifecycleEventKind` with `.{entity}Created`, `.{entity}Updated`, `.{entity}Deleted` plus any custom events
   - `struct {Entity}Event: DomainEvent` with `typealias AggregateId = {Entity}.Id`, `typealias Kind = {Entity}EventKind`
   - Reference: `Modules/Items/Domain/Event/ItemEvent.swift`

3. **`Domain/Error/{Entity}Error.swift`**
   - `struct {Entity}NotFoundError: Error` with `{entity}Id: {Entity}.Id`
   - Reference: `Modules/Items/Domain/Error/ItemError.swift`

4. **`Domain/Repository/{Entity}Repository.swift`**
   - `protocol {Entity}Repository: Repository where Entity == {Entity}, Model == {Entity}Model, DTO == {Entity}DTO {}`
   - Reference: `Modules/Items/Domain/Repository/ItemRepository.swift`

#### Infrastructure Layer

5. **`Infrastructure/Model/{Entity}Model.swift`**
   - `struct {Entity}Model: Codable, Sendable`
   - `@DocumentID var id: String`
   - User-specified properties with Firestore-compatible types (Date → `Timestamp?`)
   - `createdAt: Timestamp?`, `updatedAt: Timestamp?`
   - Reference: `Modules/Items/Infrastructure/Model/ItemModel.swift`

6. **`Infrastructure/DataSource/Firestore{Entity}DataSource.swift`**
   - `struct Firestore{Entity}DataSource<T: ClientTransport>: FirestoreDataSource, {Entity}DataSource`
   - `typealias Model = {Entity}Model`, `typealias Transport = T`
   - `let suffix = "{module}"` (lowercased module name)
   - Reference: `Modules/Items/Infrastructure/DataSource/FirestoreItemDataSource.swift`

7. **`Infrastructure/Repository/Firestore{Entity}Repository.swift`**
   - `struct Firestore{Entity}Repository: {Entity}Repository`
   - Implements `fetch(byId:)`, `doInsert(entities:)`, `doUpdate(entities:)`, `doDelete(entities:)`
   - Uses mapper for entity↔model conversion
   - Reference: `Modules/Items/Infrastructure/Repository/FirestoreItemRepository.swift`

#### Application Layer

8. **`Application/DTO/{Entity}DTO.swift`**
   - `struct {Entity}DTO: Sendable, Codable`
   - All properties as API-friendly types (Date → `String?` as ISO8601)
   - Reference: `Modules/Items/Application/DTO/ItemDTO.swift`

9. **`Application/Mapper/{Entity}Mapper.swift`**
   - `struct {Entity}Mapper: Mapper, Sendable`
   - Implements `toModel(entity:)`, `toEntity(model:)`, `toDTO(entity:)`, `toDTO(model:)`
   - Date handling: `Timestamp` ↔ `Date` ↔ ISO8601 `String`
   - Reference: `Modules/Items/Application/Mapper/ItemMapper.swift`

10. **`Application/DataSource/{Entity}DataSource.swift`**
    - `protocol {Entity}DataSource: QueryableDataSource<{Entity}Model> {}`
    - Reference: `Modules/Items/Application/DataSource/ItemDataSource.swift`

11. **`Application/Command/Create{Entity}Command.swift`**
    - `struct Create{Entity}Command: Command` with nested `Payload` containing the entity's required creation properties
    - Reference: `Modules/Items/Application/Command/CreateItemCommand.swift`

12. **`Application/Command/Handler/Create{Entity}CommandHandler.swift`**
    - `struct Create{Entity}CommandHandler: CommandHandler`
    - Wraps use case execution inside `unitOfWork.execute`
    - Reference: `Modules/Items/Application/Command/Handler/CreateItemCommandHandler.swift`

13. **`Application/UseCase/Create{Entity}UseCase.swift`**
    - `struct Create{Entity}UseCase: UseCase`
    - Nested `Params` struct with creation properties
    - Validates input, creates entity, records `.created` event, inserts via repository, returns DTO
    - Reference: `Modules/Items/Application/UseCase/CreateItemUseCase.swift`

14. **`Application/Query/Get{Entity}Query.swift`**
    - `struct Get{Entity}Query: Query` with `{entity}Id: String`
    - Reference: `Modules/Items/Application/Query/GetItemQuery.swift`

15. **`Application/Query/Handler/Get{Entity}QueryHandler.swift`**
    - `struct Get{Entity}QueryHandler: QueryHandler`
    - Fetches from data source, maps model → DTO
    - Reference: `Modules/Items/Application/Query/Handler/GetItemQueryHandler.swift`

16. **`Application/Query/List{Module}Query.swift`**
    - `struct List{Module}Query: Query {}` (empty, like ListItemsQuery)
    - Reference: `Modules/Items/Application/Query/ListItemsQuery.swift`

17. **`Application/Query/Handler/List{Module}QueryHandler.swift`**
    - `struct List{Module}QueryHandler: QueryHandler`
    - Queries all from data source, maps models → DTOs
    - Reference: `Modules/Items/Application/Query/Handler/ListItemsQueryHandler.swift`

#### Presentation Layer

18. **`Presentation/Controller/{Entity}Controller.swift`**
    - `struct {Entity}Controller: Sendable`
    - Handlers: `get{Entity}(req:)`, `list{Module}(req:)`, `create{Entity}(req:)`
    - All marked `@Sendable`
    - Error handling: domain errors → 400, not found → 404, FirestoreError → 503/500
    - Reference: `Modules/Items/Presentation/Controller/ItemController.swift`

19. **`Presentation/Route/{Entity}RouteV1.swift`**
    - `struct {Entity}RouteV1: RouteCollection`
    - Routes under `"v1", "{module}"` (lowercased)
    - GET → list, GET `":{entity}Id"` → get, POST → create
    - Reference: `Modules/Items/Presentation/Route/ItemRouteV1.swift`

#### Integration

20. **`{Module}+Vapor.swift`**
    - `import Vapor` + `extension {Entity}DTO: Content {}`
    - Reference: `Modules/Items/Items+Vapor.swift`

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
  - Create `InMemoryDataSource<{Entity}Model>` with id extractor `{ $0.id }`
  - Create `InMemoryDomainEventCollector`
  - Create `StubUnitOfWorkContext`
- Create `makeRepoFactory(ds:)` helper
- Test cases:
  - **Happy path** — execute with valid params, assert DTO fields, assert `insertedModels`, assert domain events
  - **Validation error** — execute with invalid params (e.g., empty required field), assert throws `{Entity}.Error`
  - **Optional fields** — execute with nil optional fields, assert success
- Reference: `Tests/{APP_NAME}Tests/Unit/Modules/Items/CreateItemUseCaseTests.swift`

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

### CLAUDE.md
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
An `extension Application.CompositionRoot { … }` holding the full implementation block, following `Modules/Items/CompositionRoot+Items.swift` (mapper, data source factory, repository factory, use case factory, query handlers, command handler). Never put these resolutions in `Vapor+Dependencies.swift` — see `docs/conventions/CompositionRoot.md`. Repositories take `context: ctx` and resolve their data source via `dataSourceFactory("", context.transaction)` — no separate `transaction:` argument.

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
- **Trailing commas**: Use trailing commas in function calls and collections (Swift 6.2 style, matching the Items module).
- **Imports**: Only import what's needed. Domain layer imports only `Foundation`. Infrastructure imports `FirestoreAPI`, `GRPCCore`, `Logging`. Presentation imports `Vapor`.
- **Logging**: Use structured logging with metadata. Debug level for operations, trace for results, info for use case execution, error for failures.
- **Write constraints**: Only write files into `Sources/{APP_NAME}/Modules/{Module}/`, `Tests/{APP_NAME}Tests/Unit/Modules/{Module}/`, and documentation files (README.md).
