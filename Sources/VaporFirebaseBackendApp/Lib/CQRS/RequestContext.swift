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

    /// The `id` of the integration event currently being dispatched to a handler,
    /// bound by the integration event dispatcher around each handler call.
    /// `nil` outside event dispatch (the handler then runs without
    /// de-duplication). Consumed by ``InboxedCommandHandler``.
    @TaskLocal static var integrationEventId: UUID?
}
