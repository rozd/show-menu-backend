# Composition Root (wiring convention)

There is **one** Composition Root — `Application.CompositionRoot`, conforming to the
single `Application.Dependencies` protocol. That does **not** mean one *file*.

**The contract is central; the resolutions are federated.** The main file
(`App/Vapor+Dependencies.swift`) holds the full `Dependencies` protocol plus **core**
resolutions only. Every module's resolutions live in an extension file **inside that
module**:

```
Modules/<Module>/CompositionRoot+<Module>.swift   →  extension Application.CompositionRoot { … }
```

## The split

| | Main file (`App/Vapor+Dependencies.swift`) | `Modules/<Module>/CompositionRoot+<Module>.swift` |
|---|---|---|
| **Protocol** | the **whole** `Dependencies` contract, core first, then a `// MARK: <Module>` block per module | nothing — never re-declare requirements |
| **Factory typealiases** | `UseCaseFactory`, `RepositoryFactory`, `DataSourceFactory`, … | module-specific factory typealiases only (e.g. a module's own query data-source factory) |
| **Resolutions** | **core only**: transport (`client`), store handles (`appDatabase`, `directTransaction`), DDD plumbing (dispatchers, channel, `outbox`, `outboxRelay`, `unitOfWork`), cross-cutting config (idempotency, inbox) | **everything the module owns**: mapper, data source factories, repository factory, use case factories, query handlers, command handlers, event handlers, controllers |
| **Resolver** | the `Resolver` type, `Application.deps` / `Request.deps` glue | nothing |

Why the contract stays in one place: it is the app's **complete dependency surface** —
one file to read to know what exists, one type for `Partial<Dependencies>` test
overrides to key into. Why the resolutions move out: wiring is part of a module, so
adding or deleting a module is one folder, not a folder plus a growing merge-conflict
hotspot in a shared file.

## Shape of a module file

```swift
import Vapor

extension Application.CompositionRoot {

    // MARK: <Module> — Mappers
    // MARK: <Module> — Data Sources
    // MARK: <Module> — Repositories
    // MARK: <Module> — Use Cases
    // MARK: <Module> — Queries
    // MARK: <Module> — Commands
    // MARK: <Module> — Event Handlers
    // MARK: <Module> — Controllers
}
```

Ordered **bottom-up along the dependency graph** — mapper → data source → repository →
use case → handler → controller — so a reader meets each dependency before its
consumer.

Every property is a computed `var` that delegates to the shared cache, keyed by its
**own** keypath:

```swift
var userMapper: UserMapper {
    resolver.resolve(\.userMapper) {
        UserMapper()
    }
}
```

Cross-module references are just property access — `self` is the same Composition Root,
so a use case in one module may resolve another module's factory directly. That is the
payoff of keeping the contract single.

## Rules

- **Never** add a module's resolution to `Vapor+Dependencies.swift`. If it names a
  module type, it belongs in that module's file.
- **Never** declare a second `Dependencies`-style protocol per module. One contract.
- The keypath passed to `resolver.resolve(_:)` must be the property's own — a mismatch
  silently returns another dependency's cached instance.
- Store bindings (the `as! FluentTransaction` casts, the concrete
  `Fluent<Entity>DataSource`) live **only** in the module's data source factories —
  that is the one place per module allowed to name an adapter type. Repositories, use
  cases and handlers are written against the ports.
- Capture `app.logger` in the closure's capture list (`{ [logger = app.logger] … }`)
  when building a `@Sendable` factory, rather than closing over `app`.

## Adding a module

1. Create `Modules/<Module>/` with the usual DDD layers.
2. Add a `// MARK: <Module>` block of requirements to the `Dependencies` protocol.
3. Create `Modules/<Module>/CompositionRoot+<Module>.swift` implementing exactly those.
4. Register routes / migrations from the module's own `<Module>+Vapor.swift`.

Removing a module reverses steps 2–4: delete the folder, delete the protocol block.
Nothing else changes.
