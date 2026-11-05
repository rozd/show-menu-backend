# Lib

Reusable primitives shared across all bounded contexts (`Modules/`). Concrete, domain-named types live in the modules — only generic building blocks live here.

## DDD

Domain-Driven Design tactical primitives: entities/aggregates, domain & integration events, repositories, data sources, mappers, specifications, unit of work, use cases.

## CQRS

Command/Query separation: `Command`/`CommandHandler`, `Query`/`QueryHandler`, and `RequestContext` (request-scoped task-locals).

## AOP

Cross-cutting concerns (authorization today, idempotency later). Not an AOP framework — see `AOP/README.md`.

## FSM

Generic finite state machine.

## Utils

Small standalone helpers.

---

Top-level: `Partial.swift` — partial/overridable keyed container used by the dependency resolver.
