# DDD

Domain-Driven Design tactical primitives. Concrete implementations live in each module's Domain/Infrastructure layers.

- `Entity/` — `Entity`, `EntityId`, `AggregateRoot`.
- `Events/` — domain & integration events, recorder, collector, dispatcher, handlers, `TraceID`.
- `Repository/` — `Repository` protocol (entity-level abstraction).
- `DataSource/` — `DataSource` / `QueryableDataSource` + query/filter/order types.
- `Mapper/` — entity ⇄ model ⇄ DTO conversion.
- `Specification/` — composable domain-state rules (`Specification` + and/or/not combinators).
- `UnitOfWork/` — `UnitOfWork` / `UnitOfWorkContext` (transaction + domain-event collection).
- `UseCase/` — `UseCase` protocol.
- `Error/` — `DomainError`, `ValidationError`, `ApplicationError`, `MappingError`.
