//
//  FluentUnitOfWork.swift
//  ShowMenuBackend
//
//  The UnitOfWork over a Fluent-managed SQL store.
//

import Foundation
import Logging
import Fluent

// MARK: - Context

/// The ``UnitOfWorkContext`` handed to every use case inside a command.
///
/// Carries the three things a write needs: the transaction its data sources bind
/// to, the collector that gathers domain events for post-commit dispatch, and the
/// outbox channel that records integration events *inside* the transaction.
struct FluentUnitOfWorkContext: UnitOfWorkContext {
    let transaction: FluentTransaction
    let collector: any DomainEventCollector
    let outbox: OutboxIntegrationEventChannel
}

// MARK: - Unit of Work

/// The ``UnitOfWork`` over a real SQL transaction, with domain events dispatched
/// **after** the commit.
///
/// The sequence, and why each step is where it is:
///
/// 1. A fresh ``InProcessDomainEventCollector`` per execution — nothing leaks
///    between commands. (In-process is right here: the collector holds events in
///    memory until dispatch; it is not persistence.)
/// 2. `database.transaction { … }` opens the transaction and hands back the
///    connection it runs on. Everything built from that connection — data sources,
///    the outbox store — enlists automatically.
/// 3. The outbox store is bound to *that* connection, so an integration event
///    recorded by a use case is written inside the transaction and commits (or
///    rolls back) with the state change. That is the whole point of the
///    transactional outbox.
/// 4. The work runs. If it throws, Fluent rolls the transaction back and the error
///    is **rethrown unchanged**. `ConcurrencyError` in particular must reach the
///    CommandHandler intact so the edge can map it to `409`/`412`; wrapping it in a
///    store error would destroy that.
/// 5. Only *after* `transaction` returns — i.e. after `COMMIT` — are collected
///    domain events drained and dispatched. A commit failure propagates and skips
///    dispatch; handlers must never observe an event whose transaction did not
///    commit.
///
/// Note what is *not* here: no write buffer, and no commit-time re-validation of
/// concurrency preconditions. The database provides atomicity, isolation and the
/// check-and-set backstop directly.
final class FluentUnitOfWork: UnitOfWork, Sendable {

    typealias Context = FluentUnitOfWorkContext

    let dispatcher: any DomainEventDispatcher

    private let database: any Database
    private let outbox: Outbox
    private let logger: Logger

    init(
        database: any Database,
        dispatcher: any DomainEventDispatcher,
        outbox: Outbox,
        logger: Logger
    ) {
        self.database = database
        self.dispatcher = dispatcher
        self.outbox = outbox
        self.logger = logger
    }

    func execute<Result: Sendable>(
        _ work: @escaping @Sendable (FluentUnitOfWorkContext) async throws -> Result
    ) async throws -> Result {
        logger.debug("UnitOfWork executing")

        let collector = InProcessDomainEventCollector()
        let outbox = self.outbox
        let logger = self.logger
        // Captured here, restored inside — see `RequestContext.Snapshot`. FluentKit
        // runs the closure below in a `Task` started on the event loop, which
        // inherits no task-locals; without this the work would run with no
        // principal, no idempotency key and no integration-event id.
        let context = RequestContext.snapshot

        let result: Result
        do {
            result = try await database.transaction { connection in
                try await RequestContext.restore(context) {
                    let transaction = FluentTransaction.transaction(database: connection)
                    // Bound to THIS connection, so recorded integration events are
                    // written inside the transaction and commit atomically with the
                    // aggregate's state change (or roll back with it).
                    let store = FluentOutboxStore(
                        transaction: transaction,
                        table: outbox.collection,
                        logger: logger
                    )
                    return try await work(
                        FluentUnitOfWorkContext(
                            transaction: transaction,
                            collector: collector,
                            outbox: outbox.channel(store: store)
                        )
                    )
                }
            }
        } catch {
            // Fluent has already rolled back; surface the error untouched (notably
            // `ConcurrencyError`, which the edge maps to 409/412).
            logger.debug("UnitOfWork rolled back", metadata: [
                "error": .string(String(describing: error))
            ])
            throw error
        }

        let events = await collector.drain()
        logger.info("UnitOfWork committed", metadata: [
            "domainEventCount": .string(String(events.count))
        ])
        await dispatcher.dispatch(events: events)
        return result
    }
}
