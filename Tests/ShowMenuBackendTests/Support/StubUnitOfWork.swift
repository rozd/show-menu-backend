import Foundation
@testable import ShowMenuBackend

struct StubUnitOfWorkContext: UnitOfWorkContext {
    let transaction: String
    let collector: any DomainEventCollector
    let outbox: OutboxIntegrationEventChannel

    init(
        transaction: String,
        collector: any DomainEventCollector,
        outbox: OutboxIntegrationEventChannel = OutboxIntegrationEventChannel(store: InMemoryOutboxStore())
    ) {
        self.transaction = transaction
        self.collector = collector
        self.outbox = outbox
    }
}

/// A `UnitOfWork` test double that mirrors `FirestoreTransactionUnitOfWork` behavior
/// without Firestore. Creates an `InMemoryDomainEventCollector`, passes it
/// to the work closure via `StubUnitOfWorkContext`, drains events after
/// completion, and forwards them to the dispatcher.
///
/// It also mirrors the transactional outbox: each `execute` records integration
/// events into a `BufferingOutboxStore`, which is committed to `committedOutbox`
/// only when the work closure succeeds and discarded when it throws — so
/// `committedOutbox` reflects the same commit/rollback fate as the state change.
///
/// Usage:
/// ```swift
/// let spy = SpyDomainEventDispatcher()
/// let uow = StubUnitOfWork(dispatcher: spy)
/// try await uow.execute { ctx in
///     let repo = ItemRepository(context: ctx, dataSource: ds)
///     try await repo.insert(entity: item)
/// }
/// // assert on uow.dispatchedEvents, spy.dispatchedEvents, or uow.committedOutbox
/// ```
final class StubUnitOfWork: UnitOfWork, @unchecked Sendable {
    typealias Context = StubUnitOfWorkContext

    let dispatcher: any DomainEventDispatcher

    /// Outbox rows that survived a committed `execute` (empty after a rollback).
    let committedOutbox = InMemoryOutboxStore()

    private let lock = NSLock()
    private var _dispatchedEvents: [any DomainEvent] = []

    var dispatchedEvents: [any DomainEvent] {
        lock.withLock { _dispatchedEvents }
    }

    init(dispatcher: any DomainEventDispatcher = SpyDomainEventDispatcher()) {
        self.dispatcher = dispatcher
    }

    func execute<Result: Sendable>(
        _ work: @escaping @Sendable (StubUnitOfWorkContext) async throws -> Result
    ) async throws -> Result {
        let collector = InMemoryDomainEventCollector()
        let buffer = BufferingOutboxStore(target: committedOutbox)
        let context = StubUnitOfWorkContext(
            transaction: "stub",
            collector: collector,
            outbox: OutboxIntegrationEventChannel(store: buffer)
        )

        let result: Result
        do {
            result = try await work(context)
        } catch {
            // Transaction failed: discard buffered outbox rows (rollback).
            await buffer.rollback()
            throw error
        }

        // Transaction committed: outbox rows become durable, then domain events
        // dispatch (post-commit), mirroring the production unit of work. A commit
        // failure propagates and skips post-commit dispatch.
        try await buffer.commit()
        let events = await collector.drain()
        lock.withLock { _dispatchedEvents.append(contentsOf: events) }
        await dispatcher.dispatch(events: events)
        return result
    }
}
