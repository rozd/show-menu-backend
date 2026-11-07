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
| **Factory typealiases** | `UseCaseFactory`, `RepositoryFactory`, `PrefixedRepositoryFactory`, `DataSourceFactory` | module-specific factory typealiases only, if a module needs one |
| **Resolutions** | **core only**: transport (`client`); GCP (`config`, `authProvider`, `firestore`); DDD plumbing (`integrationEventRegistry`, `integrationEventDispatcher`, `integrationEventChannel`, `domainEventDispatcher`, `outbox`, `outboxRelay`, `unitOfWork`); cross-cutting config and stores (`idempotencyConfiguration`, `idempotencyStoreFactory`, `inboxConfiguration`, `inboxStoreFactory`) | **everything the module owns**: mapper, data source factories, repository factory, use case factories, query handlers, command handlers, integration event handlers |
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
    // MARK: <Module> — Query Handlers
    // MARK: <Module> — Command Handlers
    // MARK: <Module> — Integration Event Handlers   (only if the module has any)
}
```

Ordered **bottom-up along the dependency graph** — mapper → data source → repository →
use case → handler — so a reader meets each dependency before its consumer. Controllers
are not part of the composition root: they are built per request in the module's `ContractAPI+<Module>.swift` witness from `app.deps.…` handlers.

Every property is a computed `var` that delegates to the shared cache, keyed by its
**own** keypath:

```swift
var featureMapper: FeatureMapper {
    resolver.resolve(\.featureMapper) {
        FeatureMapper()
    }
}
```

Cross-module references are just property access — `self` is the same Composition Root,
so a use case in one module may resolve another module's factory directly. That is the
payoff of keeping the contract single.

Query handlers get their read transport inline: `transaction: .direct(firestore: firestore)`.
Command handlers get `unitOfWork` instead.

## Store bindings

- The `transaction as! FirestoreTransaction` cast and the concrete
  `Firestore<Entity>DataSource` (e.g. `FirestoreFeatureDataSource`) live **only** in the
  module's data source factories — that is the one place per module allowed to name an
  adapter type. Repositories, use cases and handlers are written against the ports.
- The core cross-cutting store factories (`idempotencyStoreFactory`, `inboxStoreFactory`)
  are the exception, because they are core infrastructure in the main file. They bind
  `FirestoreIdempotencyStore` / `FirestoreInboxStore` with
  `guard let txn = ctx.transaction as? FirestoreTransaction else { preconditionFailure(…) }`:
  they must run inside `FirestoreTransactionUnitOfWork`, so a non-Firestore transaction is
  a programming error, not a runtime condition.

## Rules

- **Never** add a module's resolution to `Vapor+Dependencies.swift`. If it names a
  module type, it belongs in that module's file.
- **Never** declare a second `Dependencies`-style protocol per module. One contract.
- The keypath passed to `resolver.resolve(_:)` must be the property's own — a mismatch
  silently returns another dependency's cached instance.
- Capture `app.logger` in the closure's capture list (`{ [logger = app.logger] … }`)
  when building a `@Sendable` factory, rather than closing over `app`.
- **Handler instances vs. registration.** A module's integration event handler is
  *built* in its module file (`var userCreatedIntegrationEventHandler: …`), but it is
  *subscribed* with `await app.deps.integrationEventDispatcher.register(handler:)` in
  `configure.swift` (`configureIntegrationEvents`). Registration is a startup side effect,
  not a resolution.

## Adding a module

1. Create `Modules/<Module>/` with the usual DDD layers.
2. Add a `// MARK: <Module>` block of requirements to the `Dependencies` protocol in
   `App/Vapor+Dependencies.swift`.
3. Create `Modules/<Module>/CompositionRoot+<Module>.swift` implementing exactly those.
4. Wire the module's HTTP surface and events:
   - Expose its operations contract-first (`docs/conventions/WireContract.md`): add them to
     `show-menu-contracts`, bump the tag, then add `Presentation/ContractAPI+<Module>.swift`
     building the controller from `app.deps.…` handlers, plus the access-table entries in
     `ContractAccessMiddleware`.
   - Add a `<Module>+Vapor.swift` only for the `Content` conformance of its DTOs (as
     `Catalog+Vapor.swift` and `IAM+Vapor.swift` do).
   - If it has integration event handlers, register them in `configure.swift`.

There is no migration step.

Removing a module reverses steps 2–4: delete the folder, delete the protocol block,
delete its `ContractAPI+<Module>.swift` witness (and its operations from the contract), and delete its registrations in `configure.swift`.
Nothing else changes. The IAM sample is fenced by `// USER_LIFECYCLE_BEGIN` /
`// USER_LIFECYCLE_END` markers in `Vapor+Dependencies.swift` and
`configure.swift`, which show exactly what to remove.
