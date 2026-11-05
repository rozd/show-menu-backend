---
name: create-integration-event
description: Create an IntegrationEvent type and its IntegrationEventHandler in an existing module, register both with the dispatcher and registry, and generate unit tests.
argument-hint: "[EventName]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion
---

# Create an Integration Event and Handler

You are creating a new `IntegrationEvent` type and its `IntegrationEventHandler` in an existing module. The optional hint is: **$ARGUMENTS**

Integration events cross bounded-context boundaries. They use **primitive types only** (no domain types), are `Codable` for transport, and are identified by a `kind` string discriminator.

## Pre-flight

1. Read `Package.swift` to find the executable target name (`APP_NAME`).
2. List available modules by globbing `Sources/{APP_NAME}/Modules/*/`.
3. If `$ARGUMENTS` is provided, try to parse a module name or event name from it (e.g., `Items/ItemArchived`, `UserRegistered`).
4. Read `Sources/{APP_NAME}/configure.swift` to understand the current registration setup.

## Step 1 — Ask Questions

Use `AskUserQuestion` to gather the following:

### Question 1: Target Module
Ask: "Which module should own this integration event?" with options built from discovered modules.
Skip if unambiguously identified from `$ARGUMENTS`.

### Question 2: Event Name
Ask: "What is the event name?" with options:
- **Specify name** — The user provides a name like `UserRegistered`, `OrderShipped`, `ItemArchived`

The name should describe what happened in past tense. It will be suffixed with `IntegrationEvent` automatically (e.g., `UserRegistered` → `UserRegisteredIntegrationEvent`).

### Question 3: Event Payload
Ask: "What data should the event carry?" with options:
- **Entity ID only** — Just an ID field (e.g., `userId: String`)
- **Specify fields** — The user lists `fieldName: Type` pairs (primitive types only: `String`, `Int`, `Double`, `Bool`, `Date`, `UUID`)
- **No payload** — Only metadata (id, kind, metadata)

### Question 4: Handler Behavior
Ask: "What should the handler do when this event is received?" with options:
- **Delegate to Command** — Create a Command + CommandHandler chain and delegate to it (canonical pattern)
- **Run UseCase directly** — Call a UseCase within a UnitOfWork
- **Custom logic** — The user describes the behavior
- **No handler** — Only create the event type (handler will be added later or lives in another module)

## Step 2 — Discover Module Context

Read the module's existing types to understand naming conventions:

1. Read `Modules/{Module}/Domain/Entity/{Entity}.swift` → entity name, properties
2. Read `Modules/{Module}/Application/DTO/{Entity}DTO.swift` → DTO type
3. Read `Modules/{Module}/Domain/Repository/{Entity}Repository.swift` → repository protocol
4. Read `Modules/{Module}/Application/Mapper/{Entity}Mapper.swift` → mapper type
5. If handler delegates to command: read existing commands in `Modules/{Module}/Application/Command/` for pattern reference

## Step 3 — Derive Names

| Concept | Pattern | Example (Module=Items, EventName=ItemArchived) |
|---|---|---|
| Event struct | `{EventName}IntegrationEvent` | `ItemArchivedIntegrationEvent` |
| Event kind | `"{module}.{eventName}"` (dotted, lowercased) | `"items.itemArchived"` |
| Event file | `Application/Event/{EventName}IntegrationEvent.swift` | `ItemArchivedIntegrationEvent.swift` |
| Handler struct | `{Action}On{EventName}Handler` | `ProcessOnItemArchivedHandler` |
| Handler file | `Application/Event/Handler/Integration/{Action}On{EventName}Handler.swift` | `ProcessOnItemArchivedHandler.swift` |
| Command (if delegating) | `{Action}{Entity}Command` | `ProcessArchivedItemCommand` |
| Command Handler (if delegating) | `{Action}{Entity}CommandHandler` | `ProcessArchivedItemCommandHandler` |
| Test suite | `{EventName}IntegrationEventTests` | `ItemArchivedIntegrationEventTests` |
| Handler test suite | `{Action}On{EventName}HandlerTests` | `ProcessOnItemArchivedHandlerTests` |

The handler's `{Action}` verb describes what the handler does, not the event. Ask the user what action verb to use if it's not obvious from context.

## Step 4 — Create the Integration Event

Create `Sources/{APP_NAME}/Modules/{Module}/Application/Event/{EventName}IntegrationEvent.swift`.

```swift
import Foundation

struct {EventName}IntegrationEvent: IntegrationEvent {
    static let kind = "{module}.{eventName}"

    let id: UUID
    let metadata: IntegrationEventMetadata

    // Payload fields (primitive types only)
    let {field1}: {Type1}
    let {field2}: {Type2}

    init(
        id: UUID = UUID(),
        {field1}: {Type1},
        {field2}: {Type2},
        metadata: IntegrationEventMetadata
    ) {
        self.id = id
        self.{field1} = {field1}
        self.{field2} = {field2}
        self.metadata = metadata
    }
}
```

Key rules for IntegrationEvent types:
- **Primitive types only** — `String`, `Int`, `Double`, `Bool`, `Date`, `UUID`. No domain types (`Item.Id`, `ItemDTO`, etc.) — integration events cross context boundaries.
- **`kind` is a static string** — use dotted notation: `"{module}.{camelCaseEventName}"` (e.g., `"items.itemArchived"`).
- **`metadata` uses `IntegrationEventMetadata`** — carries `origin` (module name), optional `correlationId` (`TraceID?`), and `occurredAt`.
- **All fields `Codable` and `Sendable`**.
- Reference protocol: `Lib/DDD/Events/IntegrationEvent.swift`

## Step 5 — Create the Handler (if requested)

### Pattern A: Delegate to Command (canonical)

The IntegrationEventHandler docstring specifies this as the canonical pattern. The handler creates a Command and delegates to a CommandHandler, which wraps the UseCase in a UnitOfWork.

#### Files to create:

1. **`Application/Event/Handler/Integration/{Action}On{EventName}Handler.swift`**

   ```swift
   import Foundation
   import Logging

   struct {Action}On{EventName}Handler: IntegrationEventHandler {
       typealias Event = {EventName}IntegrationEvent

       let commandHandler: {Action}{Entity}CommandHandler
       let logger: Logger

       func handle(_ event: {EventName}IntegrationEvent) async throws {
           logger.info("Handling {EventName}IntegrationEvent", metadata: [
               "eventId": .string(event.id.uuidString),
               "origin": .string(event.metadata.origin),
               "correlationId": .stringConvertible(event.metadata.correlationId ?? "nil"),
           ])

           let command = {Action}{Entity}Command(
               payload: .init(
                   // map from event fields to command payload
               ),
               metadata: CommandMetadata(
                   correlationId: event.metadata.correlationId ?? .generate()
               )
           )
           _ = try await commandHandler.handle(command)
       }
   }
   ```

   - Naming convention: `{Action}On{EventName}Handler`
   - Handlers must be **idempotent** — events may be delivered multiple times.
   - Pass `correlationId` from the event metadata to the command for distributed tracing.
   - Reference: docstring example in `Lib/DDD/Events/IntegrationEventHandler.swift`

2. **`Application/Command/{Action}{Entity}Command.swift`** — if it doesn't already exist.

3. **`Application/Command/Handler/{Action}{Entity}CommandHandler.swift`** — if it doesn't already exist.

4. **`Application/UseCase/{Action}{Entity}UseCase.swift`** — if it doesn't already exist.

Only create the Command/CommandHandler/UseCase if they don't already exist in the module. If they do exist, the handler should reference the existing types.

### Pattern B: Run UseCase directly

```swift
struct {Action}On{EventName}Handler: IntegrationEventHandler {
    typealias Event = {EventName}IntegrationEvent

    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<{Action}{Entity}UseCase>
    let logger: Logger

    func handle(_ event: {EventName}IntegrationEvent) async throws {
        logger.info("Handling {EventName}IntegrationEvent", metadata: [
            "eventId": .string(event.id.uuidString),
            "origin": .string(event.metadata.origin),
        ])

        try await unitOfWork.execute { ctx in
            let useCase = useCaseFactory(ctx)
            try await useCase.execute(params: .init(
                // map from event fields
            ))
        }
    }
}
```

### Pattern C: Custom logic

Generate the handler body based on the user's description. Still conforms to `IntegrationEventHandler`, uses structured logging, and follows Sendable rules.

### No handler

Skip handler creation entirely. Only the event type is created. The handler may be added later or live in a different module that consumes this event.

## Step 6 — Register the Event and Handler

Edit `Sources/{APP_NAME}/configure.swift`.

### If `configureIntegrationEvents` is still commented out:

Uncomment the function and the call site, then add registrations:

```swift
public func configure(_ app: Application) async throws {
    // ... existing code ...

    // Configure integration events
    await configureIntegrationEvents(app)

    // register routes
    try routes(app)
}

// MARK: - Integration Events Configuration

private func configureIntegrationEvents(_ app: Application) async {
    // Register event types for deserialization
    await app.deps.integrationEventRegistry.register({EventName}IntegrationEvent.self)

    // Register handlers
    await app.deps.integrationEventDispatcher.register(
        handler: {Action}On{EventName}Handler(
            commandHandler: app.deps.{action}{Entity}CommandHandler,
            logger: app.logger
        )
    )
}
```

### If `configureIntegrationEvents` already exists:

Add the new registrations inside it:

```swift
// In configureIntegrationEvents:
await app.deps.integrationEventRegistry.register({EventName}IntegrationEvent.self)
await app.deps.integrationEventDispatcher.register(
    handler: {Action}On{EventName}Handler(/* dependencies */)
)
```

### Two registration points are required:

1. **`integrationEventRegistry.register({EventType}.self)`** — registers the type for deserialization. Required for queue-based transport (`VaporQueueIntegrationEventChannel`) where events are serialized to `IntegrationEventEnvelope` and decoded back using the registry.

2. **`integrationEventDispatcher.register(handler: {handler})`** — registers the handler to receive dispatched events. Only needed when a handler exists.

If no handler was created, only register the event type in the registry.

## Step 7 — Create Tests

Create test files under `Tests/{APP_NAME}Tests/Unit/Modules/{Module}/`.

### Test the Integration Event itself

Create `{EventName}IntegrationEventTests.swift`:

```swift
import Testing
import Foundation
@testable import {APP_NAME}

@Suite("{EventName}IntegrationEvent")
struct {EventName}IntegrationEventTests {

    @Test("kind returns correct discriminator")
    func kindIsCorrect() {
        #expect({EventName}IntegrationEvent.kind == "{module}.{eventName}")
    }

    @Test("round-trip encoding and decoding preserves all fields")
    func roundTripCodable() throws {
        let event = {EventName}IntegrationEvent(
            {field1}: /* test value */,
            {field2}: /* test value */,
            metadata: .from(origin: "{Module}")
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode({EventName}IntegrationEvent.self, from: data)

        #expect(decoded.id == event.id)
        #expect(decoded.{field1} == event.{field1})
        #expect(decoded.{field2} == event.{field2})
        #expect(decoded.metadata.origin == "{Module}")
    }

    @Test("registry can decode the event by kind")
    func registryDecoding() async throws {
        let registry = IntegrationEventRegistry()
        await registry.register({EventName}IntegrationEvent.self)

        let event = {EventName}IntegrationEvent(
            {field1}: /* test value */,
            metadata: .from(origin: "{Module}")
        )
        let data = try JSONEncoder().encode(event)

        let decoded = try await registry.decode(
            kind: {EventName}IntegrationEvent.kind,
            from: data
        )

        let typed = try #require(decoded as? {EventName}IntegrationEvent)
        #expect(typed.id == event.id)
    }
}
```

### Test the Handler (if created)

Create `{Action}On{EventName}HandlerTests.swift`:

```swift
import Testing
import Foundation
import Logging
@testable import {APP_NAME}

@Suite("{Action}On{EventName}Handler")
struct {Action}On{EventName}HandlerTests {

    private func makeEvent(
        {field1}: {Type1} = /* default */,
        metadata: IntegrationEventMetadata = .from(origin: "test")
    ) -> {EventName}IntegrationEvent {
        {EventName}IntegrationEvent(
            {field1}: {field1},
            metadata: metadata
        )
    }

    private func makeLogger() -> Logger {
        Logger(label: "test", factory: { _ in CapturingLogHandler() })
    }
}
```

#### Test cases for Command-delegating handlers:

```swift
@Test("delegates to command handler on event")
func delegatesToCommand() async throws {
    let ds = InMemoryDataSource<{Entity}Model>(id: { $0.id })
    let spy = SpyDomainEventDispatcher()
    let uow = StubUnitOfWork(dispatcher: spy)

    let commandHandler = {Action}{Entity}CommandHandler(
        unitOfWork: uow,
        useCaseFactory: { ctx in
            {Action}{Entity}UseCase(
                context: ctx,
                repositoryFactory: { ctx in
                    Firestore{Entity}Repository(
                        mapper: {Entity}Mapper(),
                        dataSourceFactory: { _, _ in ds },
                        context: ctx
                    )
                },
                mapper: {Entity}Mapper(),
                logger: makeLogger()
            )
        },
        logger: makeLogger()
    )

    let handler = {Action}On{EventName}Handler(
        commandHandler: commandHandler,
        logger: makeLogger()
    )

    let event = makeEvent()
    try await handler.handle(event)

    // Assert side effects from the UseCase
    let inserted = await ds.insertedModels
    #expect(inserted.count == 1)
}

@Test("preserves correlation ID from event metadata")
func preservesCorrelationId() async throws {
    // Verify the correlation ID from the integration event
    // flows through to the command metadata
    let correlationId = TraceID.generate()
    let event = makeEvent(
        metadata: .from(origin: "test", correlationId: correlationId)
    )
    // ... assert correlation ID reaches the command
}
```

#### Test cases for UseCase-delegating handlers:

```swift
@Test("executes use case on event")
func executesUseCase() async throws {
    let ds = InMemoryDataSource<{Entity}Model>(id: { $0.id })
    let spy = SpyDomainEventDispatcher()
    let uow = StubUnitOfWork(dispatcher: spy)

    let handler = {Action}On{EventName}Handler(
        unitOfWork: uow,
        useCaseFactory: { ctx in
            {Action}{Entity}UseCase(
                context: ctx,
                repositoryFactory: { ctx in
                    Firestore{Entity}Repository(
                        mapper: {Entity}Mapper(),
                        dataSourceFactory: { _, _ in ds },
                        context: ctx
                    )
                },
                mapper: {Entity}Mapper(),
                logger: Logger(label: "test")
            )
        },
        logger: Logger(label: "test")
    )

    let event = makeEvent()
    try await handler.handle(event)

    let inserted = await ds.insertedModels
    #expect(inserted.count == 1)
}
```

### Create test support doubles if missing

If `Tests/{APP_NAME}Tests/Support/SpyIntegrationEventDispatcher.swift` does not exist, create it:

```swift
@testable import {APP_NAME}

actor SpyIntegrationEventDispatcher: IntegrationEventDispatcher {
    private(set) var dispatchedEvents: [any IntegrationEvent] = []
    private(set) var registeredKinds: [String] = []

    func dispatch<E: IntegrationEvent>(_ event: E) async {
        dispatchedEvents.append(event)
    }

    func register<H: IntegrationEventHandler>(handler: H) async {
        registeredKinds.append(H.Event.kind)
    }

    func reset() {
        dispatchedEvents.removeAll()
        registeredKinds.removeAll()
    }
}
```

## Step 8 — Summary

After creating all files, output:

1. **Created files** — list with full paths
2. **Modified files** — `configure.swift` (registration)
3. **Wiring instructions** — what the user must add to `Vapor+Dependencies.swift` and the module's `CompositionRoot+{Module}.swift`:

### If handler delegates to a Command that doesn't exist yet:

```swift
// Add to the Application.Dependencies protocol:
var {action}{Entity}CommandHandler: {Action}{Entity}CommandHandler { get }
var {action}{Entity}UseCaseFactory: UseCaseFactory<{Action}{Entity}UseCase> { get }

// Add to CompositionRoot+{Module}.swift:
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

### Publishing tip

Remind the user how to publish the event from wherever it originates:

```swift
await integrationEventChannel.publish(
    {EventName}IntegrationEvent(
        {field1}: value,
        metadata: .from(origin: "{Module}")
    )
)
```

This can be called from a DomainEventHandler, a Controller, an Eventarc webhook handler, or any other integration point.

## Important Rules

- **Primitive types only in events** — No domain types. Use `String` for IDs, not `Item.Id`. This ensures events remain decoupled from the originating bounded context.
- **Idempotent handlers** — Events may be delivered multiple times (at-least-once semantics). Handlers must be safe to re-execute.
- **Swift 6.2 strict concurrency** — All types must be `Sendable`. The event struct is `Codable & Sendable` by definition.
- **No file header comments** — Do not add `// Created by...` or `// Copyright...` headers.
- **Trailing commas** — Use trailing commas in function calls and collections.
- **Imports** — Event files import only `Foundation`. Handler files import `Foundation` and `Logging`.
- **Logging** — Structured logging with metadata. Include `eventId`, `origin`, and `correlationId` in handler logs.
- **`handle` is `async throws`** — Unlike `DomainEventHandler`, `IntegrationEventHandler.handle` throws. Errors are caught by the dispatcher and logged.
- **Generate working code** — Produce complete, compilable code — not stubs with TODOs.
- **Write constraints** — Event and handler files go in `Sources/{APP_NAME}/Modules/{Module}/`. Tests go in `Tests/{APP_NAME}Tests/Unit/Modules/{Module}/`. Test support doubles go in `Tests/{APP_NAME}Tests/Support/`. Registration edits `configure.swift`.
