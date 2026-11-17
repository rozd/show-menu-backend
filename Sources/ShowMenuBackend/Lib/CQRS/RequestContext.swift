import Foundation

enum RequestContext {
    @TaskLocal static var traceId: TraceID?

    /// The authenticated actor for the current request, used as the source of
    /// truth by authorization Policy Enforcement Points (see ``Ability``).
    /// Set it with `RequestContext.$principal.withValue(_:) { ... }` at a request
    /// or message boundary; PEPs fail closed when it is absent.
    @TaskLocal static var principal: (any Principal)?

    /// The client-supplied de-duplication token for the current request, read
    /// from the `Idempotency-Key` header at the edge. `nil` when the request
    /// carries no key (the command then runs without de-duplication). Consumed by
    /// ``IdempotentCommandHandler``. Set it with
    /// `RequestContext.$idempotencyKey.withValue(_:) { ... }` at the request
    /// boundary.
    @TaskLocal static var idempotencyKey: IdempotencyKey?

    /// The id of the integration event currently being processed by a handler,
    /// read from ``IntegrationEvent/id`` by the dispatcher at the message
    /// boundary. `nil` when the handler is invoked outside of event dispatch
    /// (the handler's command then runs without inbox de-duplication). Consumed
    /// by ``InboxedCommandHandler``. The dispatcher binds it with
    /// `RequestContext.$integrationEventId.withValue(_:) { ... }` around every
    /// handler invocation, so both delivery paths (in-process channel and queue
    /// job) carry it.
    @TaskLocal static var integrationEventId: UUID?
}

// MARK: - Carrying the context across a task boundary

extension RequestContext {

    /// A copy of every ``RequestContext`` value bound right now.
    ///
    /// Task-locals propagate down the structured-concurrency tree and into
    /// unstructured `Task { }`s — but only when the task is created *from* a
    /// context that has them. A task started by a callback on a foreign
    /// thread — an event loop, a driver's completion handler — inherits nothing,
    /// and every value here silently reads back as `nil`.
    ///
    /// That is not hypothetical: FluentKit bridges its async `transaction` to the
    /// `EventLoopFuture` API with `eventLoop.makeFutureWithTask { … }`, whose
    /// `Task { }` is created on the event loop. Without re-binding, a command's
    /// work would run with no principal (PEPs fail closed), no idempotency key
    /// (de-duplication silently off) and no event id (inbox de-duplication
    /// silently off) — see ``FluentUnitOfWork``.
    ///
    /// Snapshot outside the boundary, ``restore(_:)`` inside it. Adding a new
    /// task-local above means adding it in both places here, and nowhere else.
    struct Snapshot: Sendable {
        let traceId: TraceID?
        let principal: (any Principal)?
        let idempotencyKey: IdempotencyKey?
        let integrationEventId: UUID?
    }

    /// Captures the currently bound values. Cheap — four optional reads.
    static var snapshot: Snapshot {
        Snapshot(
            traceId: traceId,
            principal: principal,
            idempotencyKey: idempotencyKey,
            integrationEventId: integrationEventId
        )
    }

    /// Re-binds `snapshot` for the duration of `body`.
    static func restore<T: Sendable>(
        _ snapshot: Snapshot,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await $traceId.withValue(snapshot.traceId) {
            try await $principal.withValue(snapshot.principal) {
                try await $idempotencyKey.withValue(snapshot.idempotencyKey) {
                    try await $integrationEventId.withValue(snapshot.integrationEventId) {
                        try await body()
                    }
                }
            }
        }
    }
}
