---
name: create-entity
description: Create an Entity (AggregateRoot) with its Domain layer files (Entity, Event, Error, Repository) and unit tests in an existing or new module.
argument-hint: "[ModuleName/EntityName]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion
---

# Create a Domain Entity (AggregateRoot)

You are creating a new Entity for this Vapor/Firebase backend. The optional hint is: **$ARGUMENTS**

This skill creates the smallest atomic DDD unit — the Domain layer for an Entity. It produces 4 source files and 1 test file, suitable for adding a second entity to an existing module or for incrementally building a new module.

## Pre-flight

1. Read `Package.swift` to find the executable target name (`APP_NAME`).
2. List available modules by globbing `Sources/{APP_NAME}/Modules/*/` to find directory names.
3. If `$ARGUMENTS` is provided, try to parse a module name and/or entity name from it (e.g., `Orders/OrderLine`, `Catalog`, `Order`).

## Step 1 — Ask Questions

Use `AskUserQuestion` to gather information. Combine into as few calls as possible (max 4 questions per call).

### Question 1: Target Module
Ask: "Which module should this Entity belong to?" with options dynamically built from discovered modules, plus an option to create a new module directory:
- **Catalog** — `Modules/Catalog/`
- **Orders** — `Modules/Orders/`
- (etc., one per discovered module)
- **New module** — Create a new module directory

Skip this question if the module was unambiguously identified from `$ARGUMENTS`.

### Question 2: Entity Name
Ask: "What should the Entity be named?" with options:
- **{Derived name}** — Derived from the module name (e.g., `Orders` → `Order`)
- **Custom name** — The user will specify a name

Skip this question if the entity name was unambiguously identified from `$ARGUMENTS`.

### Question 3: Properties
Ask: "What properties should {Entity} have?" with options:
- **Use defaults** — `name: String` and `description: String?` (the simple case; `Catalog/Feature` shows `LocalizedString` fields and a partial update)
- **Specify properties** — The user will list them as `propertyName: Type` pairs

If the user specifies properties, parse them as `propertyName: Type` pairs. Optional properties should have `?` suffix on the type (e.g., `description: String?`).

### Question 4: Custom Domain Events
Ask: "Any domain events beyond standard create/update/delete?" with options:
- **Standard only** — Just created/updated/deleted lifecycle events
- **Add custom events** — The user will specify additional event kinds (e.g., `archived`, `published`)

### Question 5: Custom Validation Errors
Ask: "What validation errors should {Entity} have?" with options:
- **Standard** — One error case per required String property (e.g., `emptyName` for `name: String`)
- **Custom** — The user will specify additional error cases

Note: Questions 4 and 5 can be combined into a second `AskUserQuestion` call if needed (max 4 questions per call).

## Step 2 — Derive Names

From the module name and entity name, derive all type names:

| Concept | Pattern | Example (Module=Orders, Entity=OrderLine) |
|---|---|---|
| Module directory | `{Module}` | `Orders` |
| Entity class | `{Entity}` | `OrderLine` |
| Entity ID | `{Entity}.Id` | `OrderLine.Id` |
| Entity Error | `{Entity}.Error` | `OrderLine.Error` |
| Domain event struct | `{Entity}Event` | `OrderLineEvent` |
| Event kind enum | `{Entity}EventKind` | `OrderLineEventKind` |
| Event case created | `.{entity}Created` | `.orderLineCreated` |
| Event case updated | `.{entity}Updated` | `.orderLineUpdated` |
| Event case deleted | `.{entity}Deleted` | `.orderLineDeleted` |
| Not-found error | `{Entity}NotFoundError` | `OrderLineNotFoundError` |
| Repository protocol | `{Entity}Repository` | `OrderLineRepository` |
| Firestore model ref | `{Entity}Model` | `OrderLineModel` |
| DTO ref | `{Entity}DTO` | `OrderLineDTO` |
| ID property (camelCase) | `{entity}Id` | `orderLineId` |

## Step 3 — Create Files

**All source files** go under `Sources/{APP_NAME}/Modules/{Module}/`.
**All test files** go under `Tests/{APP_NAME}Tests/Unit/Modules/{Module}/`.

Read the corresponding Catalog module file as reference before writing each file. Follow the exact same patterns, protocols, and conventions.

### File 1: `Domain/Entity/{Entity}.swift`

```swift
import Foundation

final class {Entity}: AggregateRoot, @unchecked Sendable {
    typealias Event = {Entity}Event

    let id: {Entity}.Id
    let events: DomainEventRecorder<Event> = .init()

    private(set) var {prop1}: {Type1}
    private(set) var {prop2}: {Type2}?
    // ... user-specified properties as private(set) var ...
    private(set) var createdAt: Date?
    private(set) var updatedAt: Date?

    init(
        id: {Entity}.Id,
        {prop1}: {Type1},
        {prop2}: {Type2}? = nil,
        // ... user-specified properties ...
        createdAt: Date? = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.{prop1} = {prop1}
        self.{prop2} = {prop2}
        // ... user-specified properties ...
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func update({prop1}: {Type1}, {prop2}: {Type2}?) {
        self.{prop1} = {prop1}
        self.{prop2} = {prop2}
        // ... user-specified properties ...
        self.updatedAt = .now
    }
}

extension {Entity} {
    struct Id: EntityId {
        let rawValue: String
        init(rawValue: String) {
            self.rawValue = rawValue
        }
    }
}

extension {Entity} {
    enum Error: ValidationError {
        case empty{Prop1}
        // ... one case per required String property ...

        var errorDescription: String? {
            switch self {
            case .empty{Prop1}:
                return "{Entity} {prop1} must not be empty"
            // ... one case per error ...
            }
        }
    }

    static func validate({prop1}: {Type1}) throws {
        guard !{prop1}.isEmpty else {
            throw {Entity}.Error.empty{Prop1}
        }
        // ... one guard per required String property ...
    }
}
```

- Reference: `Modules/Catalog/Domain/Entity/Feature.swift`
- Only required `String` properties get validation guards
- The `update()` method accepts all user properties (not `id`, `createdAt`, `updatedAt`)
- Non-String or optional properties are excluded from `validate()` unless the user specifies custom validation

### File 2: `Domain/Event/{Entity}Event.swift`

```swift
import Foundation

enum {Entity}EventKind: String, LifecycleEventKind {
    case {entity}Created = "created"
    case {entity}Updated = "updated"
    case {entity}Deleted = "deleted"
    // custom events:
    // case {entity}{CustomAction} = "{customAction}"

    static let created: {Entity}EventKind = .{entity}Created
    static let updated: {Entity}EventKind = .{entity}Updated
    static let deleted: {Entity}EventKind = .{entity}Deleted
}

struct {Entity}Event: DomainEvent {
    typealias AggregateId = {Entity}.Id
    typealias Kind = {Entity}EventKind

    let id: UUID
    let aggregateId: {Entity}.Id
    let occurredAt: Date
    let kind: {Entity}EventKind

    init(id: UUID, aggregateId: {Entity}.Id, kind: {Entity}EventKind, occurredAt: Date) {
        self.id = id
        self.aggregateId = aggregateId
        self.kind = kind
        self.occurredAt = occurredAt
    }
}
```

- Reference: `Modules/Catalog/Domain/Event/FeatureEvent.swift`
- Custom event raw values should be lowercase action words (e.g., `"archived"`, `"published"`)
- Custom event cases follow `{entity}{CustomAction}` naming (e.g., `.orderLineArchived`)

### File 3: `Domain/Error/{Entity}Error.swift`

```swift
import Foundation

struct {Entity}NotFoundError: Error {
    let {entity}Id: {Entity}.Id
}
```

- Reference: `Modules/Catalog/Domain/Error/FeatureError.swift`

### File 4: `Domain/Repository/{Entity}Repository.swift`

```swift
import Foundation

protocol {Entity}Repository: Repository where Entity == {Entity}, Model == {Entity}Model, DTO == {Entity}DTO {
}
```

- Reference: `Modules/Catalog/Domain/Repository/FeatureRepository.swift`
- **Note**: `{Entity}Model` and `{Entity}DTO` types do not exist yet. This creates a known compiler error until the Infrastructure and Application layers are added. Mention this in the summary.

### File 5: `Tests/{APP_NAME}Tests/Unit/Modules/{Module}/{Entity}Tests.swift`

```swift
import Foundation
import Testing
@testable import {APP_NAME}

@Suite("{Entity} Entity")
struct {Entity}Tests {

    // MARK: - Helpers

    private func make{Entity}(
        id: {Entity}.Id = .init(rawValue: "test-id"),
        {prop1}: {Type1} = "Test {Prop1}",
        {prop2}: {Type2}? = nil,
        // ... all user properties with sensible defaults ...
        createdAt: Date? = .now,
        updatedAt: Date? = nil
    ) -> {Entity} {
        {Entity}(
            id: id,
            {prop1}: {prop1},
            {prop2}: {prop2},
            // ...
            createdAt: createdAt,
            updatedAt: updatedAt,
        )
    }

    // MARK: - Construction

    @Test("{entity} init sets all properties")
    func init_setsProperties() {
        let {entity} = make{Entity}(
            {prop1}: "My {Prop1}",
            {prop2}: "My {Prop2}",
        )

        #expect({entity}.id.rawValue == "test-id")
        #expect({entity}.{prop1} == "My {Prop1}")
        #expect({entity}.{prop2} == "My {Prop2}")
        #expect({entity}.createdAt != nil)
        #expect({entity}.updatedAt == nil)
    }

    // MARK: - Update

    @Test("{entity} update changes properties and sets updatedAt")
    func update_changesPropertiesAndSetsUpdatedAt() {
        let {entity} = make{Entity}({prop1}: "Original")

        {entity}.update({prop1}: "Updated", {prop2}: "New {Prop2}")

        #expect({entity}.{prop1} == "Updated")
        #expect({entity}.{prop2} == "New {Prop2}")
        #expect({entity}.updatedAt != nil)
    }

    // MARK: - Validation

    @Test("{entity} validation with valid input does not throw")
    func validate_validInput_doesNotThrow() {
        #expect(throws: Never.self) {
            try {Entity}.validate({prop1}: "Valid {Prop1}")
        }
    }

    @Test("{entity} validation with empty {prop1} throws empty{Prop1}")
    func validate_empty{Prop1}_throwsEmpty{Prop1}() {
        #expect(throws: {Entity}.Error.empty{Prop1}) {
            try {Entity}.validate({prop1}: "")
        }
    }

    // ... one validation error test per Error case ...

    // MARK: - Event Recording

    @Test("{entity} record and pull events returns recorded event")
    func recordAndPullEvents_returnsEvent() {
        let {entity} = make{Entity}()
        let event = {Entity}Event(
            id: UUID(),
            aggregateId: {entity}.id,
            kind: .created,
            occurredAt: .now,
        )

        {entity}.record(event: event)
        let events = {entity}.pullEvents()

        #expect(events.count == 1)
        #expect(events.first?.kind == .created)
    }

    @Test("{entity} pullEvents drains events so second pull is empty")
    func pullEvents_drains() {
        let {entity} = make{Entity}()
        let event = {Entity}Event(
            id: UUID(),
            aggregateId: {entity}.id,
            kind: .created,
            occurredAt: .now,
        )

        {entity}.record(event: event)
        _ = {entity}.pullEvents()
        let secondPull = {entity}.pullEvents()

        #expect(secondPull.isEmpty)
    }

    @Test("{entity} clearEvents removes all events")
    func clearEvents_removesAll() {
        let {entity} = make{Entity}()
        let event = {Entity}Event(
            id: UUID(),
            aggregateId: {entity}.id,
            kind: .created,
            occurredAt: .now,
        )

        {entity}.record(event: event)
        {entity}.clearEvents()
        let events = {entity}.pullEvents()

        #expect(events.isEmpty)
    }
}
```

- Use Swift Testing framework (`@Suite`, `@Test`, `#expect`)
- `@testable import {APP_NAME}`
- `make{Entity}()` helper with sensible defaults for all properties
- Tests are pure entity unit tests — no Firestore, no UnitOfWork, no InMemoryDataSource
- One validation error test per `Error` case
- Trailing commas in function calls and collections

## Step 4 — Summary

After creating all files, output:

1. **Created files** — list all 5 files with their full paths
2. **Compiler note** — The Repository protocol references `{Entity}Model` and `{Entity}DTO` which don't exist yet. This is expected — those types belong to the Infrastructure and Application layers and will be created when adding use cases.
3. **Next steps** — Suggest what to do next:
   - Use `/create-usecase` to add a UseCase (e.g., Create{Entity}) which will require building out the Application and Infrastructure layers
   - Use `/create-module` if you want a complete module with all layers at once
   - Manually add Model, DTO, Mapper, DataSource, and Controller files following the Catalog module pattern

## Important Rules

- **Swift 6.2 strict concurrency**: All types must be `Sendable`. Entities use `@unchecked Sendable`. The `DomainEventRecorder` is already `@unchecked Sendable`.
- **No file header comments**: Do not add `// Created by...` or `// Copyright...` header comments to generated files.
- **Trailing commas**: Use trailing commas in function calls and collections (Swift 6.2 style).
- **Imports**: Only import `Foundation` in the Domain layer. Tests import `Foundation`, `Testing`, and `@testable import {APP_NAME}`.
- **Write constraints**: Only write files into `Sources/{APP_NAME}/Modules/{Module}/Domain/` and `Tests/{APP_NAME}Tests/Unit/Modules/{Module}/`.
- **Generate working code**: Based on the user's answers, generate complete, compilable code — not stubs with TODO comments. The only expected compiler error is the forward reference to `{Entity}Model` and `{Entity}DTO` in the Repository protocol.
