# Operation (Domain convention)

An **Operation** is stateless, pure domain logic that coordinates **two or more
`AggregateRoot`s**, or expresses domain logic that belongs to no single aggregate.

It is a **convention**, exactly like [`Policy`](#related-conventions) — **not** a
protocol, marker, or base class, and **nothing lives under `Lib/` for it**. There is
one implementation per activity and nothing dispatches over it generically, so a
protocol would be empty ceremony.

## When to reach for one

Use an Operation when business logic needs more than one aggregate, or a decision
that isn't a single aggregate's invariant:

- A cross-aggregate decision/intent (e.g. "may these two accounts transact?").
- A coordinated mutation across aggregates (debit one, credit another).
- Domain logic that has no natural home on any one aggregate.

If the logic only reads/mutates a single aggregate, it belongs **on that aggregate**
(a method) or in a **`*Policy`**, not in an Operation.

## What an Operation is

- **Stateless and pure** — no stored state; same inputs produce the same effect.
- **A single execute-style method** — the UseCase shape, minus infrastructure.
- **Composes `Policy` and `Specification`** rather than re-deriving rules.
- **Operates only on aggregates / value objects passed in** by the UseCase.
- **Returns a domain result / decision / intent**, or mutates the passed-in
  aggregates via *their own* methods.
- **Throws domain errors only.**

## Placement & naming

- Lives in `Modules/<Module>/Domain/Operation/`.
- Named for the **activity**, and **drops any suffix** — `TransferFunds`, **not**
  `TransferFundsOperation`. The `Operation/` folder provides the namespace.
- Modeled like a `Policy`: a caseless `enum` (a namespace) with a single static,
  pure entry point.

```
Modules/<Module>/Domain/Operation/TransferFunds.swift   →  enum TransferFunds { static func execute(...) throws }
```

## The split with the UseCase

The UseCase keeps **pure orchestration**: load aggregates via the Repository → call
the Operation → persist. Cross-aggregate decisions and any multi-aggregate
`Policy`/`Specification` invocation move **out of the UseCase and into the
Operation**.

```
UseCase:    load aggregates (Repository) → call Operation → persist (Repository)
Operation:  pure cross-aggregate decision / coordinated mutation (no I/O)
```

## Do NOT

- **Do NOT** create a protocol, marker, base class, or any file under `Lib/` for
  Operation. Treat it exactly like the existing `Policy` convention.
- **Do NOT** add a suffix to the concrete type (`TransferFunds`, not
  `TransferFundsOperation`).
- **Do NOT** put a `Repository`, `async`, transaction awareness, I/O, or any
  injected dependency inside an Operation. If you need to load or save, that belongs
  in the UseCase.

## Before / after

> The types below (`Account`, `Money`, `TransferError`) are **illustrative only** —
> they are not part of this template. They show the shape of the refactor, not code
> to add.

### Before — cross-aggregate logic living inside the UseCase

```swift
struct TransferFundsUseCase: UseCase {
    struct Params: Sendable {
        let sourceId: Account.Id
        let destinationId: Account.Id
        let amount: Money
    }

    let context: any UnitOfWorkContext
    let accountRepositoryFactory: RepositoryFactory<any AccountRepository>
    let logger: Logger

    func execute(params: Params) async throws -> Void {
        let repository = accountRepositoryFactory(context)

        guard let source = try await repository.fetch(byId: params.sourceId),
              let destination = try await repository.fetch(byId: params.destinationId) else {
            throw AccountError.notFound
        }

        // ⬇︎ cross-aggregate business logic tangled into orchestration
        guard source.id != destination.id else {
            throw TransferError.sameAccount
        }
        guard source.balance >= params.amount else {
            throw TransferError.insufficientFunds
        }
        guard !destination.isFrozen else {
            throw TransferError.destinationFrozen
        }
        source.withdraw(params.amount)
        destination.deposit(params.amount)

        try await repository.update(entities: [source, destination])
    }
}
```

### After — the decision moves into `Domain/Operation/TransferFunds.swift`

```swift
// Modules/Billing/Domain/Operation/TransferFunds.swift
enum TransferFunds {
    static func execute(from source: Account, to destination: Account, amount: Money) throws {
        guard source.id != destination.id else {
            throw TransferError.sameAccount
        }
        guard source.balance >= amount else {
            throw TransferError.insufficientFunds
        }
        guard !destination.isFrozen else {
            throw TransferError.destinationFrozen
        }
        source.withdraw(amount)
        destination.deposit(amount)
    }
}
```

The UseCase is left with pure orchestration — load, delegate, persist:

```swift
func execute(params: Params) async throws -> Void {
    let repository = accountRepositoryFactory(context)

    guard let source = try await repository.fetch(byId: params.sourceId),
          let destination = try await repository.fetch(byId: params.destinationId) else {
        throw AccountError.notFound
    }

    try TransferFunds.execute(from: source, to: destination, amount: params.amount)

    try await repository.update(entities: [source, destination])
}
```

The cross-aggregate invariants are now unit-testable in isolation — pure inputs, no
Firestore, no `UnitOfWork`.

## Related conventions

- **`Policy`** — single-aggregate (or context-wide) business rule; Domain layer,
  `*Policy` suffix, static pure functions, no protocol. An Operation **composes**
  policies.
- **`Specification`** (`Lib/DDD/Specification/`) — composable boolean predicate over
  one entity (`&&` / `||` / `!`). An Operation **composes** specifications.

An Operation is the cross-aggregate sibling of these: same "pure domain logic, no
infrastructure" spirit, scoped to coordination *across* aggregates.
