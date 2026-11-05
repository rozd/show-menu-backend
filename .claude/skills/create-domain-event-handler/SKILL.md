---
name: create-domain-event-handler
description: Create a DomainEventHandler for a specific event kind in an existing module, register it with the dispatcher, and generate unit tests.
argument-hint: "[Module/EventKind]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion
---

# Create a Domain Event Handler

You are creating a `DomainEventHandler` that reacts to a domain event within an existing module. The optional hint is: **$ARGUMENTS**

## Pre-flight

1. Read `Package.swift` to find the executable target name (`APP_NAME`).
2. List available modules by globbing `Sources/{APP_NAME}/Modules/*/`.
3. If `$ARGUMENTS` is provided, try to parse a module name and/or event kind from it (e.g., `Items/itemCreated`, `Items`, `ItemCreated`).

## Step 1 — Discover Module Context

For each candidate module, read its event file to discover available event kinds:

- Read `Modules/{Module}/Domain/Event/{Entity}Event.swift` to find:
  - The `{Entity}EventKind` enum and its cases (e.g., `.itemCreated`, `.itemUpdated`, `.itemDeleted`)
  - The `{Entity}Event` struct name

Also read the entity file for context:
- Read `Modules/{Module}/Domain/Entity/{Entity}.swift` to understand entity properties

## Step 2 — Ask Questions

Use `AskUserQuestion` to gather the following:

### Question 1: Target Module
Ask: "Which module owns the domain event?" with options built from discovered modules.
Skip if unambiguously identified from `$ARGUMENTS`.

### Question 2: Event Kind
Ask: "Which event kind should the handler react to?" with options built from the module's `{Entity}EventKind` enum. Example for Items:
- **itemCreated** — React when an item is created
- **itemUpdated** — React when an item is updated
- **itemDeleted** — React when an item is deleted
- **All kinds** — React to every event kind (no kind filter in handler)

### Question 3: Handler Action
Ask: "What should the handler do when the event fires?" with options:
- **Run a UseCase** — Delegate to an existing or new UseCase (handler wraps in UnitOfWork)
- **Publish Integration Event** — Notify other bounded contexts via IntegrationEventChannel
- **Custom logic** — The user will describe the behavior

If the user selects "Run a UseCase", also ask whether to use an existing UseCase from the module or create a new one inline.

## Step 3 — Derive Names

| Concept | Pattern | Example (Module=Items, Entity=Item, Kind=itemCreated, Action=Notify) |
|---|---|---|
| Handler struct | `{Action}On{Entity}{PascalKind}Handler` | `NotifyOnItemCreatedHandler` |
| Handler file | `Application/Event/Handler/Domain/{Action}On{Entity}{PascalKind}Handler.swift` | `NotifyOnItemCreatedHandler.swift` |
| Event type | `{Entity}Event` | `ItemEvent` |
| Event kind | `.{entityKind}` | `.itemCreated` |
| Test suite | `{Action}On{Entity}{PascalKind}HandlerTests` | `NotifyOnItemCreatedHandlerTests` |

Where `{PascalKind}` is the event kind case converted to PascalCase without the entity prefix (e.g., `itemCreated` → `Created`, `itemDeleted` → `Deleted`).

If the handler reacts to **all kinds**, name it `{Action}On{Entity}EventHandler` (e.g., `AuditOnItemEventHandler`).

## Step 4 — Create the Handler

Create `Sources/{APP_NAME}/Modules/{Module}/Application/Event/Handler/Domain/{HandlerName}.swift`.

### Pattern A: Handler that runs a UseCase

```swift
import Foundation
import Logging

struct {HandlerName}: DomainEventHandler {
    typealias Event = {Entity}Event

    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<{Action}{Entity}UseCase>
    let logger: Logger

    func handle(event: {Entity}Event) async {
        // Filter by kind (omit guard if handling all kinds)
        guard event.kind == .{eventKind} else { return }

        logger.info("Handling {Entity}Event.{eventKind}", metadata: [
            "aggregateId": .string(event.aggregateId.rawValue),
            "eventId": .string(event.id.uuidString),
        ])

        do {
            try await unitOfWork.execute { ctx in
                let useCase = useCaseFactory(ctx)
                try await useCase.execute(params: .init(
                    {entity}Id: event.aggregateId
                ))
            }
        } catch {
            logger.error("Failed to handle {Entity}Event.{eventKind}", metadata: [
                "aggregateId": .string(event.aggregateId.rawValue),
                "error": .string(error.localizedDescription),
            ])
        }
    }
}
```

- The handler's `handle(event:)` method is `async` (not throwing) — errors must be caught and logged.
- Filter by `event.kind` if the handler only reacts to one kind.
- Wrap UseCase call in `unitOfWork.execute` to get a transactional context.
- Reference protocol: `Lib/DDD/Events/DomainEventHandler.swift`

### Pattern B: Handler that publishes an Integration Event

```swift
import Foundation
import Logging

struct {HandlerName}: DomainEventHandler {
    typealias Event = {Entity}Event

    let integrationEventChannel: any IntegrationEventChannel
    let logger: Logger

    func handle(event: {Entity}Event) async {
        guard event.kind == .{eventKind} else { return }

        logger.info("Publishing integration event for {Entity}Event.{eventKind}", metadata: [
            "aggregateId": .string(event.aggregateId.rawValue),
        ])

        await integrationEventChannel.publish(
            {Entity}{PascalKind}IntegrationEvent(
                {entity}Id: event.aggregateId.rawValue,
                metadata: .from(origin: "{Module}")
            )
        )
    }
}
```

- If the IntegrationEvent type doesn't exist, create it alongside the handler (in the same module or in a shared location).

### Pattern C: Custom logic

Generate the handler body based on the user's description. The handler still conforms to `DomainEventHandler` and follows the same structure — `typealias Event`, kind filter, structured logging, error handling.

## Step 5 — Register the Handler

Edit `Sources/{APP_NAME}/configure.swift` to register the handler with the domain event dispatcher.

### If no domain event registration section exists yet:

Add a `configureDomainEventHandlers` function and call it from `configure(_:)`:

```swift
public func configure(_ app: Application) async throws {
    // ... existing code ...

    // Configure domain event handlers
    await configureDomainEventHandlers(app)

    // register routes
    try routes(app)
}

// MARK: - Domain Event Handlers

private func configureDomainEventHandlers(_ app: Application) async {
    await app.deps.domainEventDispatcher.register(
        handler: {HandlerName}(
            // inject dependencies from app.deps
        )
    )
}
```

### If the section already exists:

Add a new `register(handler:)` call inside the existing `configureDomainEventHandlers` function.

### Handler dependencies

The handler's dependencies determine what to pass during registration:

- **UseCase pattern**: needs `unitOfWork: app.deps.unitOfWork`, `useCaseFactory: app.deps.{action}{Entity}UseCaseFactory`, `logger: app.logger`
- **Integration Event pattern**: needs `integrationEventChannel: app.deps.integrationEventChannel`, `logger: app.logger`
- **Custom**: pass whatever dependencies the handler requires from `app.deps`

## Step 6 — Create Tests

Create `Tests/{APP_NAME}Tests/Unit/Modules/{Module}/{HandlerName}Tests.swift`.

Use Swift Testing framework (`@Suite`, `@Test`, `#expect`, `#require`) with `@testable import {APP_NAME}`.

### Test structure:

```swift
@Suite("{HandlerName}")
struct {HandlerName}Tests {

    // MARK: - Helpers

    private func makeEvent(
        kind: {Entity}EventKind,
        aggregateId: {Entity}.Id = .generate()
    ) -> {Entity}Event {
        {Entity}Event(
            id: UUID(),
            aggregateId: aggregateId,
            kind: kind,
            occurredAt: .now
        )
    }
}
```

### Test cases:

#### For kind-filtered handlers:

1. **Matching event kind triggers action**
   - Create the handler with test doubles
   - Call `handler.handle(event:)` with a matching event kind
   - Assert the action happened (UseCase called / integration event published / custom effect)

2. **Non-matching event kind is ignored**
   - Call `handler.handle(event:)` with a different event kind
   - Assert no action happened

#### For UseCase-delegating handlers:

- Use `InMemoryDataSource<{Entity}Model>` and `StubUnitOfWork` to verify the UseCase was executed
- Assert domain events were dispatched through the StubUnitOfWork
- Assert the data source reflects the expected changes

```swift
@Test("handles {eventKind} by executing UseCase")
func handles{PascalKind}() async throws {
    let ds = InMemoryDataSource<{Entity}Model>(id: { $0.id })
    // Seed data if the UseCase fetches an existing entity
    // await ds.seed(model)

    let spy = SpyDomainEventDispatcher()
    let uow = StubUnitOfWork(dispatcher: spy)

    let handler = {HandlerName}(
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

    let event = makeEvent(kind: .{eventKind})
    await handler.handle(event: event)

    // Assert UseCase side effects
    let inserted = await ds.insertedModels
    // ... assertions based on what the UseCase does
}

@Test("ignores non-matching event kinds")
func ignoresOtherKinds() async {
    let spy = SpyDomainEventDispatcher()
    let uow = StubUnitOfWork(dispatcher: spy)

    let handler = {HandlerName}(
        unitOfWork: uow,
        useCaseFactory: { _ in fatalError("should not be called") },
        logger: Logger(label: "test")
    )

    let event = makeEvent(kind: .{otherKind})
    await handler.handle(event: event)

    // Verify UseCase was NOT called (no events dispatched, no data changes)
    #expect(uow.dispatchedEvents.isEmpty)
}
```

#### For Integration Event publishing handlers:

- Create a spy/mock for `IntegrationEventChannel` that captures published events
- Assert the correct integration event was published with expected fields

```swift
@Test("publishes integration event on {eventKind}")
func publishes{PascalKind}IntegrationEvent() async {
    let channel = SpyIntegrationEventChannel()

    let handler = {HandlerName}(
        integrationEventChannel: channel,
        logger: Logger(label: "test")
    )

    let aggregateId = {Entity}.Id.generate()
    let event = makeEvent(kind: .{eventKind}, aggregateId: aggregateId)
    await handler.handle(event: event)

    let published = await channel.publishedEvents
    #expect(published.count == 1)
}
```

If a `SpyIntegrationEventChannel` doesn't exist in `Tests/Support/`, create it:

```swift
actor SpyIntegrationEventChannel: IntegrationEventChannel {
    private(set) var publishedEvents: [any IntegrationEvent] = []

    func publish<E: IntegrationEvent>(_ event: E) async {
        publishedEvents.append(event)
    }
}
```

Place it in `Tests/{APP_NAME}Tests/Support/SpyIntegrationEventChannel.swift`.

## Step 7 — Summary

After creating all files, output:

1. **Created files** — list with full paths
2. **Modified files** — `configure.swift` (handler registration)
3. **Wiring instructions** — if the handler delegates to a UseCase that needs to be added to the `Application.Dependencies` protocol (in `Vapor+Dependencies.swift`) and the module's `CompositionRoot+{Module}.swift` extension:

```swift
// Add to the Application.Dependencies protocol:
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
```

## Important Rules

- **Swift 6.2 strict concurrency**: All types must be `Sendable`. Closures use `@Sendable`.
- **No file header comments**: Do not add `// Created by...` or `// Copyright...` header comments.
- **Trailing commas**: Use trailing commas in function calls and collections (Swift 6.2 style).
- **Imports**: Handler files import `Foundation` and `Logging`. Only add more if needed.
- **Logging**: Structured logging with metadata. Info level for handling, error level for failures.
- **Error handling in handlers**: `DomainEventHandler.handle(event:)` is `async` not `async throws`. Catch all errors inside the handler and log them — never let errors escape.
- **Handler directory**: Place handlers in `Application/Event/Handler/Domain/` within the module.
- **Generate working code**: Produce complete, compilable code based on the user's answers — not stubs with TODO comments.
- **Write constraints**: Handler and test files go in `Sources/{APP_NAME}/Modules/{Module}/` and `Tests/{APP_NAME}Tests/Unit/Modules/{Module}/`. Registration edits `configure.swift`. Test support doubles go in `Tests/{APP_NAME}Tests/Support/`.
