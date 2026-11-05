# CQRS

Command Query Responsibility Segregation primitives.

- `Command` / `CommandHandler` — writes; go through the `UnitOfWork`. A handler implements the transaction-scoped `perform(_:in:)`; the defaulted `handle` opens one `unitOfWork.execute` around it. This split lets a cross-cutting refinement (e.g. `IdempotentCommandHandler`) compose work **inside** the same transaction.
- `Query` / `QueryHandler` — reads; skip the `UnitOfWork`.
- `RequestContext` — request-scoped `@TaskLocal`s (`traceId`, `principal`, `idempotencyKey`).
