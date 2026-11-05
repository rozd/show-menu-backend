---
name: create-usecase
description: Add a new UseCase to an existing DDD module with the appropriate trigger (REST API, Domain Event, or Integration Event) and unit tests.
argument-hint: "[UseCaseName]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion
---

# Add a UseCase to an Existing Module

You are adding a new UseCase to an existing module. The optional hint is: **$ARGUMENTS**

## Pre-flight

1. Read `Package.swift` to find the executable target name (`APP_NAME`).
2. List available modules by globbing `Sources/{APP_NAME}/Modules/*/` to find directory names.
3. If `$ARGUMENTS` is provided, try to parse a module name or use-case name from it (e.g., `Catalog/ArchiveFeature`, `ArchiveFeature`, `Catalog`).

## Step 1 — Ask Questions

Use `AskUserQuestion` to gather the following (combine into one call where possible):

### Question 1: Target Module
Ask: "Which module should this UseCase be added to?" with options dynamically built from the modules found in pre-flight. Example:
- **Catalog** — `Modules/Catalog/`
- **Orders** — `Modules/Orders/`
- (etc., one per discovered module)

Skip this question if the module was unambiguously identified from `$ARGUMENTS`.

### Question 2: Trigger Type
Ask: "How is this UseCase triggered?" with options:
- **REST API** — Exposed as an HTTP endpoint (Command + CommandHandler + Controller route)
- **Domain Event** — Reacts to an event from within this bounded context (DomainEventHandler)
- **Integration Event** — Reacts to a cross-context event, e.g., from Eventarc or another module (IntegrationEventHandler)
- **Internal** — Called only by other UseCases or services, no external trigger

### Question 3: UseCase Action & Behavior
Ask: "Describe what this UseCase does" with options:
- **Create** — Creates a new entity and persists it
- **Update** — Modifies an existing entity by ID
- **Delete** — Removes an entity by ID
- **Custom** — The user will describe the behavior

If the user selects Custom, they should provide:
- Action verb (e.g., `Archive`, `Approve`, `Send`, `Process`)
- Brief description of what the use case does
- Whether it writes data (needs UnitOfWork + Repository) or is read-only

### Question 4: UseCase Parameters
Ask: "What parameters does this UseCase need?" with options:
- **Entity ID only** — Just the entity's ID (common for Update/Delete)
- **Entity ID + payload** — ID plus additional fields (e.g., update fields)
- **Custom payload** — The user will specify parameter names and types
- **No parameters** — Triggered without input (e.g., scheduled cleanup)

## Step 2 — Discover Module Context

Before generating code, read the module's existing files to understand its types:

1. Read `Modules/{Module}/Domain/Entity/{Entity}.swift` → get entity name, properties, `{Entity}.Error` cases, validation methods
2. Read `Modules/{Module}/Domain/Event/{Entity}Event.swift` → get event kind enum name and existing events
3. Read `Modules/{Module}/Domain/Repository/{Entity}Repository.swift` → get repository protocol name
4. Read `Modules/{Module}/Infrastructure/Repository/Firestore{Entity}Repository.swift` → understand repo implementation
5. Read `Modules/{Module}/Application/Mapper/{Entity}Mapper.swift` → get mapper name
6. Read `Modules/{Module}/Application/DTO/{Entity}DTO.swift` → get DTO type
7. Read `Modules/{Module}/Infrastructure/Model/{Entity}Model.swift` → get model type
8. If REST API trigger: read `Modules/{Module}/Presentation/Controller/{Entity}Controller.swift` and `Modules/{Module}/Presentation/Route/{Entity}RouteV1.swift`

This gives you all the concrete type names to use in generated code.

## Step 3 — Derive Names

| Concept | Pattern | Example (Action=Archive, Entity=Feature) |
|---|---|---|
| UseCase | `{Action}{Entity}UseCase` | `ArchiveFeatureUseCase` |
| UseCase Params | `{Action}{Entity}UseCase.Params` | `ArchiveFeatureUseCase.Params` |
| Command | `{Action}{Entity}Command` | `ArchiveFeatureCommand` |
| Command Payload | `{Action}{Entity}Command.Payload` | `ArchiveFeatureCommand.Payload` |
| Command Handler | `{Action}{Entity}CommandHandler` | `ArchiveFeatureCommandHandler` |
| Domain Event Handler | `{Action}On{Entity}{EventKind}Handler` | `ArchiveOnFeatureCreatedHandler` |
| Integration Event Handler | `{Action}On{IntegrationEvent}Handler` | `ArchiveOnUserDeletedHandler` |
| Controller method | `{action}{Entity}(req:)` | `archiveFeature(req:)` |
| Test suite | `{Action}{Entity}UseCaseTests` | `ArchiveFeatureUseCaseTests` |
| Domain event kind | `.{entity}{Action}d` or `.{entity}{Action}ed` | `.featureArchived` |

## Step 4 — Create Files by Trigger Type

**All source files** go under `Sources/{APP_NAME}/Modules/{Module}/`.
**All test files** go under `Tests/{APP_NAME}Tests/Unit/Modules/{Module}/`.

Read the corresponding reference files from the Catalog module before writing. Follow exact same conventions.

---

### Trigger: REST API

Creates a Command → CommandHandler → UseCase chain exposed as an HTTP endpoint.

#### Files to create:

1. **`Application/UseCase/{Action}{Entity}UseCase.swift`**

   ```swift
   struct {Action}{Entity}UseCase: UseCase {
       struct Params: Sendable {
           // parameters from user input
       }

       let context: any UnitOfWorkContext
       let repositoryFactory: RepositoryFactory<any {Entity}Repository>
       let mapper: any Mapper<{Entity}, {Entity}Model, {Entity}DTO>
       let logger: Logger

       func execute(params: Params) async throws -> {ReturnType} {
           logger.info("Executing {Action}{Entity}UseCase")
           // Implementation based on user's description:
           // - For Create: validate → create entity → record .created event → insert → return DTO
           // - For Update: fetch by ID → validate → mutate entity → record .updated event → insert → return DTO
           // - For Delete: fetch by ID → record .deleted event → delete → return void
           // - For Custom: implement based on user description
       }
   }
   ```

   - If the UseCase **writes data**: it receives `context: any UnitOfWorkContext` and `repositoryFactory`
   - If the UseCase is **read-only**: it receives `dataSourceFactory: DataSourceFactory<{Entity}Model>` and `mapper` (no context/repository)
   - Reference: `Modules/Catalog/Application/UseCase/CreateFeatureUseCase.swift`

2. **`Application/Command/{Action}{Entity}Command.swift`**

   ```swift
   struct {Action}{Entity}Command: Command {
       struct Payload: Sendable, Codable {
           // fields matching the HTTP request body
       }

       let payload: Payload
       let metadata: CommandMetadata
   }
   ```

   - Reference: `Modules/Catalog/Application/Command/CreateFeatureCommand.swift`

3. **`Application/Command/Handler/{Action}{Entity}CommandHandler.swift`**

   ```swift
   struct {Action}{Entity}CommandHandler: CommandHandler {
       let unitOfWork: any UnitOfWork
       let useCaseFactory: UseCaseFactory<{Action}{Entity}UseCase>
       let logger: Logger

       func handle(_ command: {Action}{Entity}Command) async throws -> {ReturnType} {
           logger.info("Handling {Action}{Entity}Command", metadata: [
               "correlationId": .stringConvertible(command.metadata.correlationId)
           ])
           return try await unitOfWork.execute { ctx in
               let useCase = useCaseFactory(ctx)
               return try await useCase.execute(params: .init(/* map from command.payload */))
           }
       }
   }
   ```

   - Reference: `Modules/Catalog/Application/Command/Handler/CreateFeatureCommandHandler.swift`

4. **Update `Presentation/Controller/{Entity}Controller.swift`** — Add a new property for the command handler and a new endpoint method:

   ```swift
   // Add property:
   let {action}{Entity}CommandHandler: {Action}{Entity}CommandHandler

   // Add method:
   @Sendable
   func {action}{Entity}(req: Request) async throws -> Response {
       // Decode payload, create command, call handler, return response
   }
   ```

   - For Update/Delete: extract `{entity}Id` from `req.parameters.get("{entity}Id")`
   - Error handling: domain errors → 400, not found → 404, FirestoreError → 503/500
   - Reference: `FeatureController.createFeature(req:)`

5. **Update `Presentation/Route/{Entity}RouteV1.swift`** — Add the new route:

   ```swift
   // For Create-like: {module}.post("subresource", use: controller.{action}{Entity})
   // For Update: {module}.put(":{entity}Id", use: controller.{action}{Entity})
   // For Delete: {module}.delete(":{entity}Id", use: controller.{action}{Entity})
   // For Custom: choose appropriate HTTP method and path
   ```

---

### Trigger: Domain Event

Creates a DomainEventHandler that reacts to an event from this bounded context, then delegates to a UseCase.

#### Files to create:

1. **`Application/UseCase/{Action}{Entity}UseCase.swift`** — Same as REST API pattern above, but:
   - Parameters typically come from the domain event (aggregate ID, event data)
   - May or may not need UnitOfWork depending on whether it writes data

2. **`Application/Event/Handler/Domain/{Action}On{Entity}{EventKind}Handler.swift`**

   ```swift
   struct {Action}On{Entity}{EventKind}Handler: DomainEventHandler {
       typealias Event = {Entity}Event

       let useCaseFactory: UseCaseFactory<{Action}{Entity}UseCase>
       let unitOfWork: any UnitOfWork
       let logger: Logger

       func handle(event: {Entity}Event) async {
           // Filter by event kind if the handler only reacts to specific kinds
           guard event.kind == .{entityEventKind} else { return }

           logger.info("Handling {Entity}Event", metadata: [
               "kind": .string(event.kind.rawValue),
               "aggregateId": .string(event.aggregateId.rawValue)
           ])

           do {
               try await unitOfWork.execute { ctx in
                   let useCase = useCaseFactory(ctx)
                   try await useCase.execute(params: .init(
                       {entity}Id: event.aggregateId
                   ))
               }
           } catch {
               logger.error("Failed to handle {Entity}Event", metadata: [
                   "error": .string(error.localizedDescription)
               ])
           }
       }
   }
   ```

   - Reference protocol: `Lib/DDD/Events/DomainEventHandler.swift`
   - If the event kind doesn't exist yet, add it to `{Entity}EventKind` enum in `Domain/Event/{Entity}Event.swift`

3. **Optionally add a new event kind** — If the UseCase records a new event kind (e.g., `.featureArchived`), update `Domain/Event/{Entity}Event.swift` to add the new case to `{Entity}EventKind`.

---

### Trigger: Integration Event

Creates an IntegrationEventHandler that reacts to a cross-context event and delegates to a Command.

#### Files to create:

1. **`Application/UseCase/{Action}{Entity}UseCase.swift`** — Same as above.

2. **`Application/Command/{Action}{Entity}Command.swift`** and **`Application/Command/Handler/{Action}{Entity}CommandHandler.swift`** — Same as REST API pattern (the handler delegates to UseCase via CommandHandler).

3. **`Application/Event/Handler/Integration/{Action}On{IntegrationEvent}Handler.swift`**

   ```swift
   struct {Action}On{IntegrationEvent}Handler: IntegrationEventHandler {
       typealias Event = {IntegrationEventType}

       let commandHandler: {Action}{Entity}CommandHandler
       let logger: Logger

       func handle(_ event: {IntegrationEventType}) async throws {
           logger.info("Handling {IntegrationEventType}", metadata: [
               "eventId": .string(event.id.uuidString),
               "origin": .string(event.metadata.origin),
           ])

           let command = {Action}{Entity}Command(
               payload: .init(/* map from event fields */),
               metadata: CommandMetadata(
                   correlationId: event.metadata.correlationId ?? .generate()
               )
           )
           _ = try await commandHandler.handle(command)
       }
   }
   ```

   - Naming convention: `{Action}On{IntegrationEvent}Handler`
   - The handler creates a Command and delegates to the CommandHandler
   - Reference: `Lib/DDD/Events/IntegrationEventHandler.swift` (see docstring example)

4. **Optionally create the IntegrationEvent type** if it doesn't exist yet:

   ```swift
   struct {IntegrationEventType}: IntegrationEvent {
       static let kind = "{module}.{eventName}"
       let id: UUID
       let metadata: IntegrationEventMetadata
       // event-specific fields
   }
   ```

---

### Trigger: Internal

Creates only the UseCase (no external trigger). Called by other UseCases or services directly.

#### Files to create:

1. **`Application/UseCase/{Action}{Entity}UseCase.swift`** — Same as above. No Command, no Handler, no Controller changes.

---

## Step 5 — Create Tests

Create `Tests/{APP_NAME}Tests/Unit/Modules/{Module}/{Action}{Entity}UseCaseTests.swift`.

Follow the test patterns from `FeatureUseCaseTests.swift`:

- Use Swift Testing framework (`@Suite`, `@Test`, `#expect`, `#require`)
- `@testable import {APP_NAME}`
- `makeSUT()` returns `(ds: InMemoryDataSource<{Entity}Model>, collector: InMemoryDomainEventCollector, context: StubUnitOfWorkContext)`
- `makeRepoFactory(ds:)` helper creates `RepositoryFactory` with `InMemoryDataSource`

### Test cases to generate (adapt based on the action):

**For Create-like UseCases:**
- Happy path — valid params → assert DTO, assert `ds.insertedModels`, assert domain events
- Validation error — invalid params → assert throws `{Entity}.Error`
- Optional fields — nil optionals → assert success

**For Update-like UseCases:**
- Happy path — seed entity, update with valid params → assert DTO reflects changes, assert `.updated` event
- Entity not found — update non-existent ID → assert throws `{Entity}NotFoundError`
- Validation error — invalid update params → assert throws

**For Delete-like UseCases:**
- Happy path — seed entity, delete → assert `ds.deletedIds`, assert `.deleted` event
- Entity not found — delete non-existent ID → assert throws `{Entity}NotFoundError`

**For Custom UseCases:**
- Happy path — based on user's description
- Error cases — based on validation rules described

**For Domain/Integration Event triggered UseCases:**
- Also test the handler itself:
  - Handler receives matching event → delegates to UseCase
  - Handler receives non-matching event kind → ignores (for DomainEventHandler with kind filter)

To seed test data, use `await ds.seed(models:)` on the `InMemoryDataSource`.

Reference: `Tests/{APP_NAME}Tests/Unit/Modules/Catalog/FeatureUseCaseTests.swift`

## Step 6 — Summary

After creating all files, output:

1. **Created files** — list with paths
2. **Modified files** — list files that were edited (Controller, Route, EventKind enum)
3. **Wiring instructions** — what the user must add to `Vapor+Dependencies.swift` and optionally `routes.swift`:

### For REST API trigger, add to the `Application.Dependencies` protocol:
```swift
var {action}{Entity}UseCaseFactory: UseCaseFactory<{Action}{Entity}UseCase> { get }
var {action}{Entity}CommandHandler: {Action}{Entity}CommandHandler { get }
```

### For REST API trigger, add to the module's `CompositionRoot+{Module}.swift`:
```swift
var {action}{Entity}UseCaseFactory: UseCaseFactory<{Action}{Entity}UseCase> {
    resolver.resolve(\.{action}{Entity}UseCaseFactory) {
        { [logger = app.logger] ctx in
            {Action}{Entity}UseCase(
                context: ctx,
                repositoryFactory: {entity}RepositoryFactory,
                mapper: {entity}Mapper,
                logger: logger
            )
        }
    }
}

var {action}{Entity}CommandHandler: {Action}{Entity}CommandHandler {
    resolver.resolve(\.{action}{Entity}CommandHandler) {
        {Action}{Entity}CommandHandler(
            unitOfWork: unitOfWork,
            useCaseFactory: {action}{Entity}UseCaseFactory,
            logger: app.logger
        )
    }
}
```

### For REST API trigger, update `routes.swift`:
- Add the new command handler to the Controller constructor
- The route was already added by editing `{Entity}RouteV1`

### For Domain Event trigger, add to Dependencies and register handler:
```swift
// In configure.swift, register the handler with the domain event dispatcher:
// await domainEventDispatcher.register(handler: {action}On{Entity}{EventKind}Handler(...))
```

### For Integration Event trigger, add to Dependencies and register handler:
```swift
// In configure.swift (configureIntegrationEvents), register the handler with the integration event dispatcher:
// await integrationEventDispatcher.register(handler: {action}On{IntegrationEvent}Handler(...))
```

## Important Rules

- **Swift 6.2 strict concurrency**: All types must be `Sendable`. Entities use `@unchecked Sendable`. Closures use `@Sendable`.
- **No file header comments**: Do not add `// Created by...` or `// Copyright...` header comments to generated files.
- **Trailing commas**: Use trailing commas in function calls and collections (Swift 6.2 style).
- **Imports**: Only import what's needed. Application layer imports `Foundation` and `Logging`.
- **Logging**: Use structured logging with metadata. Info level for use case execution, debug for operations, error for failures.
- **Write constraints**: Only write files into `Sources/{APP_NAME}/Modules/{Module}/` and `Tests/{APP_NAME}Tests/Unit/Modules/{Module}/`.
- **Existing code**: When editing Controller or Route files, preserve all existing code. Only add new properties, methods, and routes.
- **Generate working code**: Based on the user's answers, generate complete, compilable code — not stubs with TODO comments. Infer reasonable implementations from the action verb and context.
